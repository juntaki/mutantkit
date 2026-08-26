import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof of the design doc's own open question 1 ("Compile-
/// viability rate of the exclusion heuristics"): every shape
/// `SideEffectCallRemovalOperator` proposes a candidate for actually
/// type-checks once the candidate is applied, confirmed by invoking the
/// real Swift compiler (`swiftc -typecheck`) — not merely asserted from
/// the RED tests' syntax-only assertions. Mirrors
/// `CoreOperatorCompileViabilityAcceptanceTests`' own approach.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: side-effect call removal compile viability", .enabled(if: Acceptance.isEnabled))
struct SideEffectCallRemovalCompileViabilityAcceptanceTests {
    private let operatorID = "swift.core.side-effect-call-removal"

    /// A full compile, not `-typecheck` — found necessary empirically,
    /// not assumed: `swiftc -typecheck` alone does **not** produce
    /// "missing return in function expected to return 'T'" or
    /// "`super.init` isn't called on all paths before returning from
    /// initializer" (confirmed directly against both fixture shapes:
    /// exit 0 under `-typecheck`, exit 1 with the exact diagnostic under
    /// a full compile) — both are definite-initialization/flow-sensitive
    /// diagnostics from a later compiler phase than type-checking proper.
    /// Every test in this file uses this, not `-typecheck`, so a false
    /// "succeeded" from an under-strength check can never mask a real
    /// compile-viability gap the way it did before this was found.
    private func compiles(_ source: String) throws -> (succeeded: Bool, output: String) {
        try invokeSwiftc(source, arguments: ["-o", "/dev/null"])
    }

    private func invokeSwiftc(_ source: String, arguments: [String]) throws -> (succeeded: Bool, output: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-effect-compile-viability-\(UUID().uuidString).swift")
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc"] + arguments + [file.path]
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

    /// A minimal preamble every fixture below needs, since none of them
    /// declare their own helper functions — every "side effect" is a
    /// bare, already-declared top-level function, kept out of each
    /// individual fixture so the diff each test asserts about stays
    /// focused on the one shape it exists to prove.
    private static let preamble = """
    func prepare() {}
    func sideEffect() {}
    func finish() {}
    func cleanup() {}
    func work() {}
    func notify() {}
    func after() {}
    func logCall() {}

    """

    @Test("A plain statement removal (scenario 1/2) still type-checks")
    func plainStatementRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func run() {
            prepare()
            sideEffect()
            finish()
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0 == "sideEffect()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A call inside a defer block (scenario 4) still type-checks once removed")
    func deferBodyRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func run() {
            defer {
                cleanup()
            }
            work()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "cleanup()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A try call (scenario 5) still type-checks once the whole try expression is removed")
    func tryCallRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func throwingSideEffect() throws {}

        func run() throws {
            try throwingSideEffect()
            work()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "try throwingSideEffect()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("An await call (scenario 6) still type-checks once the whole await expression is removed")
    func awaitCallRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func asyncSideEffect() async {}

        func run() async {
            await asyncSideEffect()
            work()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "await asyncSideEffect()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A try await call (scenario 7) still type-checks once both wrappers are removed together")
    func tryAwaitCallRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func asyncThrowingSideEffect() async throws {}

        func run() async throws {
            try await asyncThrowingSideEffect()
            work()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "try await asyncThrowingSideEffect()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A sole statement of a Void-annotated closure completion handler (scenario 8) still type-checks once removed")
    func explicitVoidClosureRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func perform(completion: () -> Void) {
            completion()
        }

        func run() {
            perform(completion: { () -> Void in
                notify()
            })
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "notify()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A call inside an if block body (scenario 9) still type-checks once removed")
    func ifBlockBodyRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func run(condition: Bool) {
            if condition {
                sideEffect()
            }
            after()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "sideEffect()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("The last of several statements in an unannotated closure (scenario 10) still type-checks once removed")
    func lastOfSeveralStatementsInUnannotatedClosureTypeChecks() throws {
        let source = Self.preamble + """
        func run() {
            let g: () -> Void = {
                logCall()
                notify()
            }
            g()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "notify()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A non-last statement of a guard's else block still type-checks once removed")
    func nonLastGuardElseStatementRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func run(condition: Bool) {
            guard condition else {
                logCall()
                fatalError()
            }
            after()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "logCall()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A non-sole statement of a switch case still type-checks once removed")
    func nonSoleSwitchCaseStatementRemovalTypeChecks() throws {
        let source = Self.preamble + """
        enum State { case ready }

        func run(state: State) {
            switch state {
            case .ready:
                logCall()
                notify()
            }
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "logCall()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    // MARK: - Real-corpus/codex-review findings: proving the exclusions are load-bearing, not superstition

    /// The operator no longer proposes any of these three shapes as
    /// candidates (see the corresponding RED tests), so this proves the
    /// *danger the exclusion exists to prevent* is real, by mutating the
    /// source directly (not through the operator) and confirming a real
    /// `swiftc` failure — the same standard
    /// `CoreOperatorCompileViabilityAcceptanceTests` holds arithmetic's
    /// own exclusions to.
    @Test("Removing a trailing call to a custom Never-returning function actually breaks compilation")
    func trailingCustomNeverCallRemovalActuallyFailsToCompile() throws {
        let source = """
        func customNeverHelper() -> Never {
            fatalError()
        }

        func value() -> Int {
            let audited = 1
            customNeverHelper()
        }
        """
        // Deliberately not run through the operator's own discovery -- it
        // no longer proposes this site at all. Mutated by hand to prove
        // the hazard the exclusion prevents is real, not hypothetical.
        //
        // Uses `compiles` (a full compile), not `typeChecks`: confirmed
        // empirically that `swiftc -typecheck` alone does NOT catch
        // "missing return" -- that is a later, flow-sensitive diagnostic
        // pass, not part of type-checking proper.
        let mutated = source.replacingOccurrences(of: "    customNeverHelper()\n", with: "")
        #expect(mutated != source, "the replacement must actually match something")
        let originalResult = try compiles(source)
        #expect(originalResult.succeeded, "\(originalResult.output)")
        let mutatedResult = try compiles(mutated)
        #expect(!mutatedResult.succeeded, "removing the trailing Never call should break compilation")
    }

    @Test("Removing super.init(...) actually breaks compilation")
    func superInitRemovalActuallyFailsToCompile() throws {
        let source = """
        class Base {
            init(value: Int) {}
        }

        class Sub: Base {
            override init(value: Int) {
                super.init(value: value)
            }
        }
        """
        // `compiles`, not `typeChecks`: confirmed empirically that
        // `-typecheck` does not catch a missing `super.init` either --
        // "isn't called on all paths before returning from initializer"
        // is the same class of flow-sensitive, definite-initialization
        // diagnostic as "missing return" above.
        let mutated = source.replacingOccurrences(of: "super.init(value: value)\n", with: "")
        #expect(mutated != source, "the replacement must actually match something")
        #expect(try compiles(source).succeeded)
        let mutatedResult = try compiles(mutated)
        #expect(!mutatedResult.succeeded, "removing super.init should break compilation")
    }

    @Test("Removing self.init(...) delegation actually breaks compilation")
    func selfInitRemovalActuallyFailsToCompile() throws {
        let source = """
        struct S {
            let value: Int

            init(value: Int) {
                self.value = value
            }

            init() {
                self.init(value: 0)
            }
        }
        """
        // Not leading-whitespace-anchored: Swift's multi-line string
        // literal dedents to the closing `"""`'s own indentation, which
        // does not match this source file's visual indentation -- an
        // exact-whitespace pattern silently fails to match, leaving the
        // "mutated" source identical to the original (confirmed the hard
        // way: an earlier version of this exact line never matched, so
        // this test passed for the wrong reason -- comparing against
        // unmutated source, not against the actual hazard).
        let mutated = source.replacingOccurrences(of: "self.init(value: 0)\n", with: "")
        #expect(mutated != source, "the replacement must actually match something")
        #expect(try compiles(source).succeeded)
        let mutatedResult = try compiles(mutated)
        #expect(!mutatedResult.succeeded, "removing self.init delegation should break compilation")
    }

    @Test("An ordinary self.foo() call and a subscript's explicit set accessor's sole statement still type-check once removed")
    func selfMethodCallAndSubscriptSetterRemovalTypeCheck() throws {
        let source = Self.preamble + """
        struct Table {
            var storage: [Int: Int] = [:]

            func sideEffect() {}

            func run() {
                self.sideEffect()
                after()
            }

            subscript(index: Int) -> Int {
                get { storage[index] ?? 0 }
                set { store(index, newValue) }
            }
        }

        func store(_ index: Int, _ value: Int) {}
        """
        #expect(try compiles(source).succeeded)

        let mutatedSelf = try mutatedSource(source) { $0 == "self.sideEffect()" }
        let selfResult = try compiles(mutatedSelf)
        #expect(selfResult.succeeded, "\(selfResult.output)")

        let mutatedSetter = try mutatedSource(source) { $0 == "store(index, newValue)" }
        let setterResult = try compiles(mutatedSetter)
        #expect(setterResult.succeeded, "\(setterResult.output)")
    }
}
