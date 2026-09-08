import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof, via a real `swiftc` compile against the actual `UIKit`
/// module on the current Apple SDK (not only a fake minimal stand-in), that
/// `ForegroundEventReplacementOperator`'s mutation compiles for every shape
/// its own matcher accepts, in both directions.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case, against the iOS simulator SDK):
/// `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: foreground-event-replacement compile viability", .enabled(if: Acceptance.isEnabled))
struct ForegroundEventReplacementCompileViabilityAcceptanceTests {
    private let operatorID = "apple.lifecycle.foreground-event-replacement"

    /// A full compile against the iOS simulator SDK -- required because
    /// `UIApplication`/`UIKit` do not exist in the default macOS SDK this
    /// process otherwise targets.
    private func compiles(_ source: String) throws -> (succeeded: Bool, output: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreground-event-replacement-compile-viability-\(UUID().uuidString).swift")
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "--sdk", "iphonesimulator", "swiftc",
            "-target", "arm64-apple-ios17.0-simulator",
            "-o", "/dev/null", file.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    private func mutatedSource(_ source: String, candidateMatching predicate: (String) -> Bool) throws -> String {
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(
            points.first { predicate($0.originalText) },
            "expected a matching mutation candidate among \(points.map(\.originalText))"
        )
        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        return String(decoding: applied.mutatedSource, as: UTF8.self)
    }

    private static let preamble = "import UIKit\n\n"

    @Test("let name = UIApplication.didBecomeActiveNotification, mutated to willEnterForeground, still type-checks")
    func plainLetDidBecomeActiveTypeChecks() throws {
        let source = Self.preamble + """
        let name: Notification.Name = UIApplication.didBecomeActiveNotification
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("didBecomeActiveNotification") }
        #expect(mutated.contains("willEnterForegroundNotification"))
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("let name = UIApplication.willEnterForegroundNotification, mutated to didBecomeActive, still type-checks (the inverse form)")
    func plainLetWillEnterForegroundTypeChecks() throws {
        let source = Self.preamble + """
        let name: Notification.Name = UIApplication.willEnterForegroundNotification
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("willEnterForegroundNotification") }
        #expect(mutated.contains("didBecomeActiveNotification"))
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A real NotificationCenter.addObserver(forName:) call site, mutated, still type-checks")
    func addObserverCallSiteTypeChecks() throws {
        let source = Self.preamble + """
        final class LifecycleObserver {
            var token: NSObjectProtocol?
            func register() {
                token = NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { _ in }
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("didBecomeActiveNotification") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A real #selector-based addObserver call site, mutated, still type-checks")
    func selectorBasedAddObserverTypeChecks() throws {
        let source = Self.preamble + """
        final class LifecycleObserver: NSObject {
            func register() {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleForeground),
                    name: UIApplication.willEnterForegroundNotification,
                    object: nil
                )
            }
            @objc func handleForeground() {}
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("willEnterForegroundNotification") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("An array literal of both notification names, each mutated independently, still type-checks")
    func arrayLiteralTypeChecks() throws {
        let source = Self.preamble + """
        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification
        ]
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutatedA = try mutatedSource(source) { $0.contains("didBecomeActiveNotification") }
        #expect(try compiles(mutatedA).succeeded)

        let mutatedB = try mutatedSource(source) { $0.contains("willEnterForegroundNotification") }
        #expect(try compiles(mutatedB).succeeded)
    }

    @Test("A multiline member access, mutated, still type-checks")
    func multilineMemberAccessTypeChecks() throws {
        let source = Self.preamble + """
        let name = UIApplication
            .didBecomeActiveNotification
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("didBecomeActiveNotification") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }
}
