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

    func testDeadOwnerLockIsReclaimed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockRoot = root.appendingPathComponent(".mutantkit/run-locks")
        try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)

        let destination = "stale-destination"
        let lockURL = RunIsolationLock.lockURL(
            projectRoot: root.resolvingSymlinksInPath().standardizedFileURL,
            lockRoot: lockRoot.resolvingSymlinksInPath().standardizedFileURL,
            destination: destination
        )
        let stale = RunIsolationLockMetadata(
            pid: 2_000_000_000,
            startedAt: Date(timeIntervalSince1970: 0),
            projectRoot: root.path,
            destination: destination,
            hostname: "stale-host",
            token: "stale-token"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stale).write(to: lockURL, options: .atomic)

        let replacement = try RunIsolationLock.acquire(
            projectRoot: root,
            lockRoot: lockRoot,
            destination: destination
        )
        replacement.release()
    }

    /// The user-facing gap this closes: `.corruptLock`'s own `description`
    /// used to stop at "refusing to delete it automatically", with no
    /// indication of what the user should actually do next.
    func testCorruptLockDescriptionNamesTheRemedy() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockRoot = root.appendingPathComponent(".mutantkit/run-locks")
        try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)

        let lockURL = RunIsolationLock.lockURL(
            projectRoot: root.resolvingSymlinksInPath().standardizedFileURL,
            lockRoot: lockRoot.resolvingSymlinksInPath().standardizedFileURL,
            destination: "corrupt-destination"
        )
        // Not valid JSON, so `RunIsolationLockMetadata` decoding fails and
        // `acquire` cannot prove whether the lock is stale or genuinely owned.
        try Data("not json".utf8).write(to: lockURL, options: .atomic)

        do {
            _ = try RunIsolationLock.acquire(
                projectRoot: root,
                lockRoot: lockRoot,
                destination: "corrupt-destination"
            )
            XCTFail("an unreadable lock must fail closed, not be silently reclaimed")
        } catch let error as RunIsolationLockError {
            guard case .corruptLock = error else {
                return XCTFail("unexpected lock error: \(error)")
            }
            XCTAssertTrue(error.description.contains("rm '\(lockURL.path)'"), error.description)
        }
    }

    /// Caught by `codex review`: presented as a command to copy-paste and
    /// run, `rm <path>` is silently wrong (or dangerous) for a project
    /// checked out under a path containing a space, unless the path is
    /// quoted — `RunIsolationLockError.description` only, not a real `rm`
    /// invocation, so this checks the rendered string directly.
    func testCorruptLockRemedyQuotesAPathContainingASpace() {
        let error = RunIsolationLockError.corruptLock(path: "/Users/dev/My Project/.mutantkit/run-locks/run-abc.lock")
        XCTAssertTrue(
            error.description.contains("rm '/Users/dev/My Project/.mutantkit/run-locks/run-abc.lock'"),
            error.description
        )
    }

    /// Caught by `codex review`: a naive "wrap in single quotes only when
    /// the path has a space" rule still breaks for a path that itself
    /// contains a single quote (a real, valid checkout name like
    /// `O'Brien Project`) — the embedded `'` would terminate the
    /// surrounding quoted string early, producing invalid shell syntax.
    func testCorruptLockRemedyEscapesAnEmbeddedSingleQuote() {
        let error = RunIsolationLockError.corruptLock(path: "/Users/dev/O'Brien Project/.mutantkit/run-locks/run-abc.lock")
        XCTAssertTrue(
            error.description.contains("rm '/Users/dev/O'\\''Brien Project/.mutantkit/run-locks/run-abc.lock'"),
            error.description
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-RunIsolationLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
