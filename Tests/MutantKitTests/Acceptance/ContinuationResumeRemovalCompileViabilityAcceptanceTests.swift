import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof, via a real `swiftc` compile, of every claim
/// `ContinuationResumeRemovalOperator`'s own doc comment makes about which
/// shapes are safe to mutate and which are excluded — mirrors
/// `SideEffectCallRemovalCompileViabilityAcceptanceTests`' own approach.
/// This is the suite that originally found the operator's own guard
/// conditions (see the type's doc comment for the direct `swiftc` findings
/// this suite's assertions are built from): the fault-taxonomy research
/// document this operator is grounded in was itself wrong about two of its
/// three proposed exclusions (`if`/`catch` bodies do not need the
/// sole-statement guard `switch` needs — both compile fine empty), found
/// here by actually invoking the compiler rather than trusting the
/// document's syntax-only reasoning.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: continuation-resume-removal compile viability", .enabled(if: Acceptance.isEnabled))
struct ContinuationResumeRemovalCompileViabilityAcceptanceTests {
    private let operatorID = "apple.concurrency.continuation-resume-removal"

    /// A full compile, not `-typecheck` — same reasoning as
    /// `SideEffectCallRemovalCompileViabilityAcceptanceTests`: some
    /// diagnostics this suite cares about (definite-initialization,
    /// missing-return) only surface at a later compiler phase. Continuation
    /// resume removal has not been found to trigger either class so far,
    /// but using the stronger check costs nothing and keeps this suite
    /// consistent with its sibling.
    private func compiles(_ source: String) throws -> (succeeded: Bool, output: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuation-resume-compile-viability-\(UUID().uuidString).swift")
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-o", "/dev/null", file.path]
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

    private static let preamble = """
    enum SomeError: Error { case failed }
    func log() {}
    func prepare() {}
    func finish() {}
    func risky() throws {}

    """

    @Test("A bare resume() removal still type-checks")
    func bareResumeRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func complete(_ continuation: CheckedContinuation<Void, Never>) {
            prepare()
            continuation.resume()
            finish()
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0 == "continuation.resume()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("resume(returning:) removal still type-checks")
    func resumeReturningRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func complete(_ continuation: CheckedContinuation<Int, Never>) {
            continuation.resume(returning: 42)
            finish()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0.contains("resume(returning:") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("resume(throwing:) removal still type-checks")
    func resumeThrowingRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func complete(_ continuation: CheckedContinuation<Void, Error>) {
            continuation.resume(throwing: SomeError.failed)
            finish()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0.contains("resume(throwing:") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("resume(with:) removal still type-checks")
    func resumeWithRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func complete(_ continuation: CheckedContinuation<Int, Error>, _ result: Result<Int, Error>) {
            continuation.resume(with: result)
            finish()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0.contains("resume(with:") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing the sole resume() of an if branch still type-checks (empty if body is valid Swift)")
    func soleStatementOfIfBranchRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func complete(_ continuation: CheckedContinuation<Void, Never>, _ ready: Bool) {
            if ready {
                continuation.resume()
            }
            finish()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "continuation.resume()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing the sole resume() of a catch body still type-checks (empty catch body is valid Swift)")
    func soleStatementOfCatchBodyRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func complete(_ continuation: CheckedContinuation<Void, Never>) {
            do {
                try risky()
            } catch {
                continuation.resume()
            }
            finish()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "continuation.resume()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing the sole resume() of an explicit-parameter closure still type-checks")
    func soleStatementOfExplicitParameterClosureRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func completeAll(_ continuations: [CheckedContinuation<Void, Never>?]) {
            continuations.forEach { cont in
                cont?.resume()
            }
            finish()
        }
        """
        #expect(try compiles(source).succeeded)

        let mutated = try mutatedSource(source) { $0 == "cont?.resume()" }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A switch case whose sole statement is resume() is never proposed as a candidate at all")
    func switchCaseSoleStatementIsNeverACandidate() throws {
        let source = Self.preamble + """
        enum Action {
            case finish(CheckedContinuation<Void, Never>)
            case none
        }

        func complete(_ action: Action) {
            switch action {
            case .finish(let continuation):
                continuation.resume()
            case .none:
                break
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(
            !points.contains { $0.originalText == "continuation.resume()" },
            "the operator's own switch-case exclusion must prevent this non-compiling mutation from ever being proposed"
        )
    }

    @Test("An implicit-parameter closure whose sole statement is resume() is never proposed as a candidate at all")
    func implicitParameterClosureSoleStatementIsNeverACandidate() throws {
        let source = Self.preamble + """
        func completeAll(_ continuations: [CheckedContinuation<Void, Never>?]) {
            continuations.forEach { $0?.resume() }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(
            !points.contains { $0.originalText == "$0?.resume()" },
            "the operator's own implicit-parameter-closure exclusion must prevent this non-compiling mutation from ever being proposed"
        )
    }

    // MARK: - Found on real code: sole resume() inside a continuation-creating closure

    /// Found on `apple/swift-nio`'s real corpus (2026-09), not written from a
    /// fixture-only guess: `withCheckedContinuation { continuation in ... }`
    /// infers its generic `Success` type from a `resume`/`resume(returning:)`
    /// call reachable in the closure body. Confirmed directly here with a
    /// real `swiftc` invocation before the operator's guard was written.
    @Test("A sole resume() inside withCheckedContinuation's closure is never proposed as a candidate at all")
    func soleResumeInContinuationCreatingClosureIsNeverACandidate() throws {
        let source = Self.preamble + """
        import Dispatch

        final class Thing {
            let queue = DispatchQueue(label: "q")
            func doSomething() {}
            func advanceTime() async {
                await withCheckedContinuation { continuation in
                    self.queue.async {
                        self.doSomething()
                        continuation.resume()
                    }
                }
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(
            !points.contains { $0.originalText == "continuation.resume()" },
            """
            the operator's own continuation-creating-closure exclusion must prevent this \
            non-compiling mutation ("generic parameter 'T' could not be inferred") from ever \
            being proposed
            """
        )
    }

    /// The mirror image of the case above: a second `resume`-family call
    /// elsewhere in the same continuation closure is enough for the
    /// compiler's inference, confirmed directly, so removing *one* of the
    /// two still type-checks and the operator's guard must not over-exclude.
    @Test("Removing one of two resume() calls in the same continuation closure still type-checks")
    func oneOfTwoResumeCallsInSameContinuationClosureRemovalTypeChecks() throws {
        let source = Self.preamble + """
        func advanceTime(_ flag: Bool) async {
            await withCheckedContinuation { continuation in
                if flag {
                    continuation.resume()
                } else {
                    continuation.resume()
                }
            }
            finish()
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.filter { $0.originalText == "continuation.resume()" }.count == 2)

        let point = try #require(points.first { $0.originalText == "continuation.resume()" })
        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        let mutated = String(decoding: applied.mutatedSource, as: UTF8.self)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    /// Found by adversarial review (round 2) of the guard above, then
    /// confirmed directly with a real `swiftc` compile before the fix
    /// landed: `DispatchSourceTimer`/`DispatchSourceProtocol.resume()` is a
    /// real stdlib API, name-identical to a continuation's `resume()`, that
    /// plausibly co-occurs with one in timeout/cancellation code. Matching
    /// `resume` by method name alone when deciding whether *another* call
    /// keeps the continuation's own type inference alive — as opposed to
    /// discovery itself, which matches by name deliberately — would let this
    /// unrelated call mask the fact that the continuation's own `resume()`
    /// is its closure's sole pin, exactly reproducing the "generic parameter
    /// 'T' could not be inferred" failure this guard exists to prevent.
    @Test("A same-named resume() on an unrelated receiver does not save the mutation from being non-compiling")
    func sameNamedResumeOnUnrelatedReceiverIsStillExcluded() throws {
        let source = Self.preamble + """
        import Dispatch

        func waitForSignal(_ timerSource: DispatchSourceTimer) async {
            await withCheckedContinuation { continuation in
                timerSource.resume()
                continuation.resume()
            }
            finish()
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(
            !points.contains { $0.originalText == "continuation.resume()" },
            """
            an unrelated same-named resume() call must not be mistaken for a second call on the \
            same continuation -- deleting continuation.resume() here does not compile
            ("generic parameter 'T' could not be inferred")
            """
        )

        // The unrelated timerSource.resume() is still its own, independent
        // candidate (name-only matching, same as everywhere else in this
        // operator) -- and removing it alone must still type-check, since it
        // has nothing to do with the continuation's own inference.
        let point = try #require(points.first { $0.originalText == "timerSource.resume()" })
        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        let mutated = String(decoding: applied.mutatedSource, as: UTF8.self)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }
}
