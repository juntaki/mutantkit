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
    case corruptLock(path: String)
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
        case let .corruptLock(path):
            """
            Found an unreadable MutantKit run lock at \(path). Refusing to delete it automatically:
            without owner metadata MutantKit cannot prove that no active run owns the lock.
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
/// The lock is acquired with `O_CREAT | O_EXCL`, so ownership is decided by the
/// filesystem rather than by a check-then-create race. A lock whose PID no
/// longer exists is reclaimed automatically. A malformed lock fails closed.
public final class RunIsolationLock: @unchecked Sendable {
    private let url: URL
    private let token: String
    private let fileManager = FileManager.default
    private var released = false

    private init(url: URL, token: String) {
        self.url = url
        self.token = token
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
        let fm = FileManager.default
        try fm.createDirectory(at: lockRoot, withIntermediateDirectories: true)

        let canonicalRoot = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalLockRoot = lockRoot.resolvingSymlinksInPath().standardizedFileURL
        let url = lockURL(
            projectRoot: canonicalRoot,
            lockRoot: canonicalLockRoot,
            destination: destination
        )

        for _ in 0 ..< 3 {
            let token = UUID().uuidString
            let metadata = RunIsolationLockMetadata(
                pid: getpid(),
                startedAt: Date(),
                projectRoot: canonicalRoot.path,
                destination: destination,
                hostname: ProcessInfo.processInfo.hostName,
                token: token
            )

            let data = try JSONEncoder.lockEncoder.encode(metadata)
            let fd = url.path.withCString { path in
                Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            }
            if fd >= 0 {
                defer { Darwin.close(fd) }
                let written = data.withUnsafeBytes { bytes in
                    Darwin.write(fd, bytes.baseAddress, bytes.count)
                }
                guard written == data.count else {
                    try? fm.removeItem(at: url)
                    throw RunIsolationLockError.cannotCreate(
                        path: url.path,
                        detail: "short write while persisting owner metadata"
                    )
                }
                _ = fsync(fd)
                return RunIsolationLock(url: url, token: token)
            }

            guard errno == EEXIST else {
                throw RunIsolationLockError.cannotCreate(
                    path: url.path,
                    detail: String(cString: strerror(errno))
                )
            }

            // The winning process writes metadata immediately after the atomic
            // create. Give it a brief chance to finish before declaring the file
            // corrupt. This avoids treating the tiny create→write window as a
            // permanent failure while still refusing to guess after repeated
            // unreadable reads.
            var existing: RunIsolationLockMetadata?
            for attempt in 0 ..< 3 {
                if let data = try? Data(contentsOf: url),
                   let decoded = try? JSONDecoder.lockDecoder.decode(RunIsolationLockMetadata.self, from: data) {
                    existing = decoded
                    break
                }
                if attempt < 2 { usleep(50000) }
            }

            guard let owner = existing else {
                throw RunIsolationLockError.corruptLock(path: url.path)
            }

            if processIsAlive(owner.pid) {
                throw RunIsolationLockError.alreadyRunning(owner)
            }

            // Stale owner: remove and retry the atomic acquisition. If another
            // contender races us here, O_EXCL on the next loop still decides the
            // winner safely.
            try? fm.removeItem(at: url)
        }

        throw RunIsolationLockError.cannotCreate(
            path: url.path,
            detail: "could not acquire the lock after reclaiming stale owners"
        )
    }

    /// Releases only a lock still owned by this instance. The token check keeps
    /// a delayed/deinitialized owner from deleting a newer process's lock.
    public func release() {
        guard !released else { return }
        released = true

        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder.lockDecoder.decode(RunIsolationLockMetadata.self, from: data),
              metadata.token == token
        else { return }

        try? fileManager.removeItem(at: url)
    }

    static func lockURL(projectRoot: URL, lockRoot: URL, destination: String) -> URL {
        let identity = projectRoot.path + "\u{1F}" + destination
        let digest = ContentHash.shortDigest(of: identity, length: 20)
        return lockRoot.appendingPathComponent("run-\(digest).lock")
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
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
