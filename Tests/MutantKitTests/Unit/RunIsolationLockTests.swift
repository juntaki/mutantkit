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

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-RunIsolationLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
