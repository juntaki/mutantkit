import Darwin
import Foundation
import MutationModel

/// Metadata persisted in a run lock so a conflicting process can explain who
/// owns the destination instead of merely reporting that a lock file exists.
public struct RunIsolationLockMetadata: Codable, Sendable, Equatable {
    public let pid: Int32
    public let startedAt: Date
    public let projectRoot: String
    public let destination: String
    public let hostname: String
    public let token: String

    public init(
        pid: Int32,
        startedAt: Date,
        projectRoot: String,
        destination: String,
        hostname: String,
        token: String
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.projectRoot = projectRoot
        self.destination = destination
        self.hostname = hostname
        self.token = token
    }
}

public enum RunIsolationLockError: Error, CustomStringConvertible {
    case alreadyRunning(RunIsolationLockMetadata)
    /// Another process holds the lock but its diagnostic metadata could not be
    /// read (it is mid-write, or was damaged). Ownership is still decided by
    /// the OS lock, so this is a refusal to run, never a reclamation.
    case heldByUnidentifiedOwner(path: String)
    case cannotCreate(path: String, detail: String)

    public var description: String {
        switch self {
        case let .alreadyRunning(owner):
            """
            Another MutantKit run is already using this project/destination.
              PID          \(owner.pid)
              Started      \(owner.startedAt)
              Destination  \(owner.destination)
              Host         \(owner.hostname)
            Refusing to run concurrently because competing xcodebuild/test processes can turn
            resource contention and shared simulator state into incorrect mutation verdicts.
            """
        case let .heldByUnidentifiedOwner(path):
            """
            Another MutantKit run holds the lock at \(path), but its owner metadata is unreadable.
            Refusing to run concurrently. The lock is released by the operating system when the
            owning process exits, so retry once that run has finished; do not delete the file.
            """
        case let .cannotCreate(path, detail):
            "Could not create MutantKit run lock at \(path): \(detail)"
        }
    }
}

/// An inter-process lock for one `(project root, destination)` pair.
///
/// Mutation runs are intentionally isolated from one another. Two independent
/// MutantKit processes that target the same simulator can compete for memory,
/// xcodebuild workers and simulator state. In real-project validation this was
/// observed to change a mutant's manifestation from a deterministic crash to a
/// timeout under severe resource pressure, which in turn changes whether the
/// mutant participates in the score.
///
/// Ownership is an OS-held advisory `flock(2)` on a lock file with a stable
/// inode, held through a close-on-exec descriptor for the life of this object.
/// The kernel arbitrates contenders atomically and drops the lock when the
/// holder dies for any reason (including `kill -9`), so there is no stale-file
/// reclamation, no PID-liveness guess and no unlink of a lock that may be live.
/// The JSON in the file is diagnostic only: it explains who holds the lock and
/// is rewritten by every new owner, so truncated or stale content can never
/// make a lock unsafe or permanently stuck. The file is never deleted.
public final class RunIsolationLock: @unchecked Sendable {
    private let url: URL
    private var fd: Int32
    private let state = NSLock()

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit {
        release()
    }

    /// Acquires the lock for a project/destination pair.
    ///
    /// `lockRoot` should normally be `<project>/.mutantkit/run-locks`. The project
    /// path is still part of the digest so moving a lock directory elsewhere
    /// cannot accidentally alias a different checkout.
    public static func acquire(
        projectRoot: URL,
        lockRoot: URL,
        destination: String
    ) throws -> RunIsolationLock {
        try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)

        let canonicalRoot = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalLockRoot = lockRoot.resolvingSymlinksInPath().standardizedFileURL
        let url = lockURL(
            projectRoot: canonicalRoot,
            lockRoot: canonicalLockRoot,
            destination: destination
        )

        // O_CLOEXEC: spawned xcodebuild/simctl children must not inherit the
        // descriptor, or they would keep the lock alive after this process dies.
        let fd = url.path.withCString { path in
            Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else {
            throw RunIsolationLockError.cannotCreate(path: url.path, detail: String(cString: strerror(errno)))
        }

        // A few short attempts: the previous holder may still be writing its
        // metadata, and a read-only `heldLockCount` probe briefly takes a shared
        // lock. Neither is ownership, so retry before reporting contention.
        var lastErrno: Int32 = 0
        for attempt in 0 ..< 3 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { lastErrno = 0; break }
            lastErrno = errno
            guard lastErrno == EWOULDBLOCK else { break }
            if attempt < 2 { usleep(50000) }
        }
        if lastErrno != 0 {
            defer { Darwin.close(fd) }
            guard lastErrno == EWOULDBLOCK else {
                throw RunIsolationLockError.cannotCreate(path: url.path, detail: String(cString: strerror(lastErrno)))
            }
            if let owner = readMetadata(at: url) {
                throw RunIsolationLockError.alreadyRunning(owner)
            }
            throw RunIsolationLockError.heldByUnidentifiedOwner(path: url.path)
        }

        let metadata = RunIsolationLockMetadata(
            pid: getpid(),
            startedAt: Date(),
            projectRoot: canonicalRoot.path,
            destination: destination,
            hostname: ProcessInfo.processInfo.hostName,
            token: UUID().uuidString
        )
        do {
            let data = try JSONEncoder.lockEncoder.encode(metadata)
            guard ftruncate(fd, 0) == 0 else {
                throw RunIsolationLockError.cannotCreate(path: url.path, detail: String(cString: strerror(errno)))
            }
            let written = data.withUnsafeBytes { bytes in
                Darwin.pwrite(fd, bytes.baseAddress, bytes.count, 0)
            }
            guard written == data.count else {
                throw RunIsolationLockError.cannotCreate(
                    path: url.path,
                    detail: "short write while persisting owner metadata"
                )
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        return RunIsolationLock(url: url, fd: fd)
    }

    /// Releases the lock. Metadata is cleared while the lock is still held so a
    /// later reader never reports a departed owner; the file itself is kept.
    public func release() {
        state.lock()
        defer { state.unlock() }
        guard fd >= 0 else { return }
        _ = ftruncate(fd, 0)
        Darwin.close(fd) // closing the descriptor drops the flock
        fd = -1
    }

    /// Number of lock files under `lockRoot` that some process currently holds.
    /// Probes with a non-blocking shared lock on a fresh descriptor.
    public static func heldLockCount(in lockRoot: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: lockRoot, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "lock" }.count { file in
            let probe = file.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
            guard probe >= 0 else { return false }
            defer { Darwin.close(probe) }
            if flock(probe, LOCK_SH | LOCK_NB) == 0 { return false }
            return errno == EWOULDBLOCK
        }
    }

    static func lockURL(projectRoot: URL, lockRoot: URL, destination: String) -> URL {
        let identity = projectRoot.path + "\u{1F}" + destination
        let digest = ContentHash.shortDigest(of: identity, length: 20)
        return lockRoot.appendingPathComponent("run-\(digest).lock")
    }

    private static func readMetadata(at url: URL) -> RunIsolationLockMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.lockDecoder.decode(RunIsolationLockMetadata.self, from: data)
    }
}

private extension JSONEncoder {
    static var lockEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var lockDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
