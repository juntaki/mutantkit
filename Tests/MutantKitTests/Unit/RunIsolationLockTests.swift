import Darwin
import Foundation
@testable import MutationExecution
import XCTest

final class RunIsolationLockTests: XCTestCase {
    func testSecondOwnerForSameProjectAndDestinationIsRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockRoot = root.appendingPathComponent(".mutantkit/run-locks")

        let first = try RunIsolationLock.acquire(
            projectRoot: root,
            lockRoot: lockRoot,
            destination: "platform=iOS Simulator,name=Test Device"
        )
        defer { first.release() }

        do {
            _ = try RunIsolationLock.acquire(
                projectRoot: root,
                lockRoot: lockRoot,
                destination: "platform=iOS Simulator,name=Test Device"
            )
            XCTFail("a second live owner should not acquire the same project/destination lock")
        } catch let error as RunIsolationLockError {
            guard case let .alreadyRunning(owner) = error else {
                return XCTFail("unexpected lock error: \(error)")
            }
            XCTAssertEqual(owner.pid, getpid())
            XCTAssertEqual(owner.destination, "platform=iOS Simulator,name=Test Device")
        }
    }

    func testDifferentDestinationsCanRunIndependently() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockRoot = root.appendingPathComponent(".mutantkit/run-locks")

        let first = try RunIsolationLock.acquire(
            projectRoot: root,
            lockRoot: lockRoot,
            destination: "simulator-A"
        )
        defer { first.release() }

        let second = try RunIsolationLock.acquire(
            projectRoot: root,
            lockRoot: lockRoot,
            destination: "simulator-B"
        )
        second.release()
    }

    func testReleaseAllowsAReplacementOwner() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockRoot = root.appendingPathComponent(".mutantkit/run-locks")

        let first = try RunIsolationLock.acquire(
            projectRoot: root,
            lockRoot: lockRoot,
            destination: "same-destination"
        )
        first.release()

        let second = try RunIsolationLock.acquire(
            projectRoot: root,
            lockRoot: lockRoot,
            destination: "same-destination"
        )
        second.release()
    }

    // MARK: - OS-held ownership (the metadata is diagnostic, never the authority)

    /// A leftover file with a dead owner's metadata and no OS lock holder is
    /// simply acquired: ownership is the lock, not the PID in the file.
    func testLeftoverMetadataOfDeadOwnerDoesNotBlock() throws {
        let fixture = try LockFixture(destination: "stale-destination")
        defer { fixture.cleanup() }
        try fixture.writeRaw(fixture.metadataJSON(pid: 2_000_000_000))

        let lock = try fixture.acquire()
        lock.release()
    }

    /// PID reuse: the file names a live PID (this process) but no OS lock is
    /// held. A PID-liveness design would refuse; the OS lock design must not.
    func testMetadataNamingALivePIDWithoutAHeldLockDoesNotBlock() throws {
        let fixture = try LockFixture(destination: "pid-reuse")
        defer { fixture.cleanup() }
        try fixture.writeRaw(fixture.metadataJSON(pid: getpid()))

        let lock = try fixture.acquire()
        lock.release()
    }

    /// Truncated / garbage metadata with no holder neither blocks nor needs
    /// manual `rm`; the new owner rewrites it.
    func testTruncatedOrGarbageMetadataDoesNotBlockAndIsRewritten() throws {
        let fixture = try LockFixture(destination: "corrupt-destination")
        defer { fixture.cleanup() }
        try fixture.writeRaw(Data("{\"pid\": 12".utf8))

        let lock = try fixture.acquire()
        defer { lock.release() }
        let rewritten = try JSONDecoder.iso.decode(
            RunIsolationLockMetadata.self, from: Data(contentsOf: fixture.lockURL)
        )
        XCTAssertEqual(rewritten.pid, getpid())
    }

    /// The lock file is never unlinked and keeps its inode across release and
    /// re-acquisition, so no contender can ever lock an orphaned inode.
    func testLockFileIsNeverUnlinkedAndKeepsItsInode() throws {
        let fixture = try LockFixture(destination: "stable-inode")
        defer { fixture.cleanup() }

        let first = try fixture.acquire()
        let inodeWhileHeld = try fixture.inode()
        first.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.lockURL.path))
        XCTAssertEqual(try fixture.inode(), inodeWhileHeld)

        let second = try fixture.acquire()
        XCTAssertEqual(try fixture.inode(), inodeWhileHeld)
        second.release()
    }

    /// Many concurrent contenders: exactly one enters. (Same process, but each
    /// acquire opens its own descriptor, which `flock` arbitrates exactly like
    /// separate processes.)
    func testConcurrentContendersAdmitExactlyOneOwner() throws {
        let fixture = try LockFixture(destination: "contended")
        defer { fixture.cleanup() }
        try fixture.writeRaw(fixture.metadataJSON(pid: 2_000_000_000)) // stale file to "reclaim"

        let contenders = 16
        let results = Locked<[RunIsolationLock]>([])
        let refusals = Locked<Int>(0)
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for _ in 0 ..< contenders {
            DispatchQueue.global().async(group: group) {
                start.wait()
                do {
                    let lock = try fixture.acquire()
                    results.mutate { $0.append(lock) }
                } catch {
                    refusals.mutate { $0 += 1 }
                }
            }
        }
        for _ in 0 ..< contenders { start.signal() }
        group.wait()

        XCTAssertEqual(results.value.count, 1, "exactly one contender may own the lock")
        XCTAssertEqual(refusals.value, contenders - 1)
        results.value.forEach { $0.release() }
    }

    /// A different process holds the OS lock: we are refused (non-blocking,
    /// with diagnostics when the file carries them). Then the holder is
    /// `kill -9`ed and ownership is released by the kernel with no cleanup.
    func testForeignHolderBlocksAndKillNineReleases() throws {
        let fixture = try LockFixture(destination: "foreign")
        defer { fixture.cleanup() }
        try fixture.writeRaw(fixture.metadataJSON(pid: 4242))

        let holder = try fixture.spawnForeignHolder()
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit() } }

        let started = Date()
        do {
            _ = try fixture.acquire()
            XCTFail("a lock held by another live process must not be acquirable")
        } catch let error as RunIsolationLockError {
            switch error {
            case let .alreadyRunning(owner): XCTAssertEqual(owner.pid, 4242)
            default: XCTFail("unexpected lock error: \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "contention must not block")
        XCTAssertEqual(RunIsolationLock.heldLockCount(in: fixture.lockRoot), 1)

        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()

        let lock = try fixture.acquire()
        lock.release()
        XCTAssertEqual(RunIsolationLock.heldLockCount(in: fixture.lockRoot), 0)
    }

    /// A holder whose metadata is unreadable still blocks us (fail closed on
    /// the OS lock) with a diagnosable, non-`rm` error.
    func testHolderWithUnreadableMetadataStillBlocks() throws {
        let fixture = try LockFixture(destination: "foreign-garbage")
        defer { fixture.cleanup() }
        try fixture.writeRaw(Data("garbage".utf8))
        let holder = try fixture.spawnForeignHolder()
        defer { kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit() }

        do {
            _ = try fixture.acquire()
            XCTFail("held lock must block regardless of metadata")
        } catch let error as RunIsolationLockError {
            guard case .heldByUnidentifiedOwner = error else {
                return XCTFail("unexpected lock error: \(error)")
            }
            XCTAssertFalse(error.description.contains("rm "), error.description)
        }
    }

    /// Children spawned while the lock is held (xcodebuild, simctl) must not
    /// inherit the descriptor: otherwise they would keep the lock after the
    /// owner releases or dies.
    func testSpawnedChildDoesNotInheritTheLock() throws {
        let fixture = try LockFixture(destination: "cloexec")
        defer { fixture.cleanup() }

        let lock = try fixture.acquire()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        lock.release()

        let again = try fixture.acquire()
        again.release()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-RunIsolationLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct LockFixture {
    let root: URL
    let lockRoot: URL
    let destination: String

    init(destination: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-RunIsolationLockTests-\(UUID().uuidString)")
        lockRoot = root.appendingPathComponent(".mutantkit/run-locks")
        self.destination = destination
        try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)
    }

    var lockURL: URL {
        RunIsolationLock.lockURL(
            projectRoot: root.resolvingSymlinksInPath().standardizedFileURL,
            lockRoot: lockRoot.resolvingSymlinksInPath().standardizedFileURL,
            destination: destination
        )
    }

    func acquire() throws -> RunIsolationLock {
        try RunIsolationLock.acquire(projectRoot: root, lockRoot: lockRoot, destination: destination)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func writeRaw(_ data: Data) throws { try data.write(to: lockURL) }

    func inode() throws -> UInt64 {
        var st = stat()
        guard stat(lockURL.path, &st) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return UInt64(st.st_ino)
    }

    func metadataJSON(pid: Int32) -> Data {
        let metadata = RunIsolationLockMetadata(
            pid: pid, startedAt: Date(timeIntervalSince1970: 0), projectRoot: root.path,
            destination: destination, hostname: "other-host", token: "t"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(metadata)) ?? Data()
    }

    /// A separate process that takes `flock(LOCK_EX)` on the lock file and
    /// sleeps; returns once it reports the lock is held.
    func spawnForeignHolder() throws -> Process {
        let script = [
            "import fcntl,sys,time", "f=open(sys.argv[1],'r+')", "fcntl.flock(f,fcntl.LOCK_EX)",
            "print('held',flush=True)", "time.sleep(60)", ""
        ].joined(separator: "\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", script, lockURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let line = pipe.fileHandleForReading.availableData
        guard String(data: line, encoding: .utf8)?.hasPrefix("held") == true else {
            process.terminate()
            throw CocoaError(.fileReadUnknown)
        }
        return process
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
