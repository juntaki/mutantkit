@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

@Suite("TestInventory: complete or explicitly unknown")
struct TestInventoryTests {
    private func result(
        exit: Int32 = 0, timedOut: Bool = false, outputComplete: Bool = true
    ) -> ProcessResult {
        ProcessResult(
            exitCode: exit, standardOutput: Data(), standardError: Data(), durationSeconds: 0,
            timedOut: timedOut, terminatingSignal: nil, outputComplete: outputComplete, cleanupVerified: true
        )
    }

    @Test("A truncated capture is not an inventory, even when every captured line parses")
    func truncatedCaptureIsUnknown() {
        #expect(TestInventory.gate(result(outputComplete: false)) == .outputTruncated)
    }

    @Test("Failure and timeout are enumerationFailed")
    func failuresAreEnumerationFailed() {
        #expect(TestInventory.gate(result(exit: 1)) == .enumerationFailed("did not succeed"))
        #expect(TestInventory.gate(result(timedOut: true)) == .enumerationFailed("timed out"))
    }

    @Test("A clean, complete run passes the gate")
    func cleanRunPasses() {
        #expect(TestInventory.gate(result()) == nil)
    }

    @Test("A valid SwiftPM listing is complete and survives reconciliation with its configured target")
    func validListingIsComplete() {
        let inventory = SwiftPackageMacOSAdapter.parseTestIdentifiers("""
        AppTests.AddTests/testAdd
        AppTests.Suite/check()
        """).reconciled(withConfiguredTargets: ["AppTests"])
        #expect(inventory.tests?.count == 2)
        #expect(inventory.unknownReason == nil)
    }

    @Test("Unknown never exposes a test set, so no consumer can narrow on it")
    func unknownHasNoTests() {
        #expect(TestInventory.unknown(.noTests).tests == nil)
        #expect(TestInventory.complete([]).unknownReason == nil)
    }
}

@Suite("XCTestInvocationService: fresh result bundle")
struct FreshResultBundleTests {
    /// Fails `removeItem`, as a bundle that cannot be deleted would.
    private final class RefusingRemoval: FileManager, @unchecked Sendable {
        override func removeItem(at URL: URL) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// Fails `createDirectory`.
    private final class RefusingCreation: FileManager, @unchecked Sendable {
        override func createDirectory(
            at url: URL, withIntermediateDirectories createIntermediates: Bool,
            attributes: [FileAttributeKey: Any]?
        ) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("A previous bundle that cannot be removed stops the run instead of being read as its result")
    func failedRemovalIsReported() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("r.xcresult")
        try Data().write(to: bundle)

        let failure = XCTestInvocationService.prepareFreshResultBundle(bundle, fileManager: RefusingRemoval())
        #expect(failure?.contains("could not be removed") == true)
    }

    @Test("A result directory that cannot be created is reported")
    func failedCreationIsReported() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("r.xcresult")
        let failure = XCTestInvocationService.prepareFreshResultBundle(bundle, fileManager: RefusingCreation())
        #expect(failure?.contains("could not be created") == true)
    }

    @Test("An old bundle is removed and the path is clear for the new run")
    func oldBundleIsRemoved() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("r.xcresult")
        try Data().write(to: bundle)

        #expect(XCTestInvocationService.prepareFreshResultBundle(bundle) == nil)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
    }

    @Test("A path that never existed is fine")
    func absentBundleIsFine() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(XCTestInvocationService.prepareFreshResultBundle(directory.appendingPathComponent("n.xcresult")) == nil)
    }
}
