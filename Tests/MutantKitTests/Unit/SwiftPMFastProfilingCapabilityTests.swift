@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

// `.serialized`: `diagnosticDisableForcesUnsupported` mutates the
// process-global `MUTANTKIT_DISABLE_FAST_PROFILING` environment variable via
// setenv/unsetenv -- run concurrently with the rest of this suite, that
// leaks across tests and produces a real, order-dependent flake (confirmed
// live: `allSwiftTestingWithResolvableProductIsSupported` failing when
// scheduled inside the disable test's own setenv/unsetenv window).
@Suite("SwiftPM fast profiling capability", .serialized)
struct SwiftPMFastProfilingCapabilityTests {
    private func makeBundle(named name: String, in directory: URL) throws {
        let bundle = directory.appendingPathComponent("\(name).xctest", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("fake binary".utf8).write(to: macOS.appendingPathComponent(name))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-capability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("No discovered tests is unsupported")
    func noTestsIsUnsupported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        guard case .unsupported = SwiftPMFastProfilingCapability.check(tests: [], productsDirectory: directory) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("Every test Swift-Testing-shaped, one resolvable product: supported")
    func allSwiftTestingWithResolvableProductIsSupported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeBundle(named: "WidgetsPackageTests", in: directory)

        let tests = [
            TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetA()"),
            TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetB()")
        ]
        guard case .supported = SwiftPMFastProfilingCapability.check(tests: tests, productsDirectory: directory) else {
            Issue.record("expected supported")
            return
        }
    }

    @Test("Even one XCTest-shaped test among the discovered set is unsupported in full")
    func oneXCTestShapedTestMakesTheWholeSetUnsupported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeBundle(named: "WidgetsPackageTests", in: directory)

        let tests = [
            TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetA()"),
            TestIdentifier(target: "WidgetsXCTests", qualifiedName: "WidgetsXCTests/testWidgetB")
        ]
        guard case .unsupported = SwiftPMFastProfilingCapability.check(tests: tests, productsDirectory: directory) else {
            Issue.record("expected unsupported -- a mixed set must never get a partial fast run")
            return
        }
    }

    @Test("An unresolvable product (none, or ambiguous) is unsupported")
    func unresolvableProductIsUnsupported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // No .xctest bundle at all.

        let tests = [TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetA()")]
        guard case .unsupported = SwiftPMFastProfilingCapability.check(tests: tests, productsDirectory: directory) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test("MUTANTKIT_DISABLE_FAST_PROFILING forces unsupported regardless of the real checks")
    func diagnosticDisableForcesUnsupported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeBundle(named: "WidgetsPackageTests", in: directory)

        setenv("MUTANTKIT_DISABLE_FAST_PROFILING", "1", 1)
        defer { unsetenv("MUTANTKIT_DISABLE_FAST_PROFILING") }

        let tests = [TestIdentifier(target: "WidgetsTests", qualifiedName: "WidgetsTests/widgetA()")]
        guard case .unsupported = SwiftPMFastProfilingCapability.check(tests: tests, productsDirectory: directory) else {
            Issue.record("expected unsupported")
            return
        }
    }
}
