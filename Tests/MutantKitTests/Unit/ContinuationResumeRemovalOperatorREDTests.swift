import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// RED tests for `apple.concurrency.continuation-resume-removal`. Positive
/// scenarios prove discovery finds a real fault-shaped candidate; negative
/// scenarios prove the three exclusions in the operator's own doc comment
/// each actually fire, and were each independently verified against a real
/// `swiftc -typecheck` compile before being written here (not merely
/// asserted from syntax alone) — see
/// `ContinuationResumeRemovalCompileViabilityAcceptanceTests` for the
/// compile-time proof of the shapes this suite claims are safe to mutate.
@Suite("RED: Apple concurrency continuation-resume-removal operator")
struct ContinuationResumeRemovalOperatorREDTests {
    private let operatorID = "apple.concurrency.continuation-resume-removal"

    // MARK: - Positive scenarios

    @Test("A bare resume() as a statement in a multi-statement function body is a candidate")
    func bareResumeInMultiStatementBody() throws {
        let source = """
        func complete(_ continuation: CheckedContinuation<Void, Never>) {
            prepare()
            continuation.resume()
            finish()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "continuation.resume()" && $0.replacementText.isEmpty })
    }

    @Test("resume(returning:) as a bare statement is a candidate")
    func resumeReturningIsCandidate() throws {
        let source = """
        func complete(_ continuation: CheckedContinuation<Int, Never>) {
            continuation.resume(returning: 42)
            after()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "continuation.resume(returning: 42)" })
    }

    @Test("resume(throwing:) as a bare statement is a candidate")
    func resumeThrowingIsCandidate() throws {
        let source = """
        func complete(_ continuation: CheckedContinuation<Void, Error>) {
            continuation.resume(throwing: SomeError.failed)
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "continuation.resume(throwing: SomeError.failed)" })
    }

    @Test("resume(with:) as a bare statement is a candidate")
    func resumeWithIsCandidate() throws {
        let source = """
        func complete(_ continuation: CheckedContinuation<Int, Error>, _ result: Result<Int, Error>) {
            continuation.resume(with: result)
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "continuation.resume(with: result)" })
    }

    @Test("A resume() nested inside a nested if/else still gets found as a candidate (not the sole statement of that branch)")
    func resumeAlongsideOtherStatementInBranch() throws {
        let source = """
        func complete(_ continuation: CheckedContinuation<Void, Never>, _ ready: Bool) {
            if ready {
                log()
                continuation.resume()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "continuation.resume()" })
    }

    @Test("A resume() that is the sole statement of an if branch is a candidate (if/catch tolerate empty bodies)")
    func resumeAsSoleStatementOfIfBranchIsCandidate() throws {
        let source = """
        func complete(_ continuation: CheckedContinuation<Void, Never>, _ ready: Bool) {
            if ready {
                continuation.resume()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "continuation.resume()" })
    }

    @Test("A resume() that is the sole statement of a catch body is a candidate (if/catch tolerate empty bodies)")
    func resumeAsSoleStatementOfCatchBodyIsCandidate() throws {
        let source = """
        func complete(_ continuation: CheckedContinuation<Void, Never>) {
            do {
                try risky()
            } catch {
                continuation.resume()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "continuation.resume()" })
    }

    @Test("A resume() that is the sole statement of a closure with an explicit (even unused) parameter is a candidate")
    func resumeAsSoleStatementOfExplicitParameterClosureIsCandidate() throws {
        let source = """
        func completeAll(_ continuations: [CheckedContinuation<Void, Never>?]) {
            continuations.forEach { cont in
                cont?.resume()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "cont?.resume()" })
    }

    // MARK: - Negative scenarios

    @Test("A resume() that is the sole statement of a switch case is excluded (empty case does not compile)")
    func resumeAsSoleStatementOfSwitchCaseIsExcluded() throws {
        let source = """
        func complete(_ action: Action) {
            switch action {
            case .finish(let continuation):
                continuation.resume()
            case .none:
                break
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "continuation.resume()" })
    }

    @Test("A resume() alongside another statement in the same switch case is still a candidate")
    func resumeNotSoleStatementOfSwitchCaseIsCandidate() throws {
        let source = """
        func complete(_ action: Action) {
            switch action {
            case .finish(let continuation):
                log()
                continuation.resume()
            case .none:
                break
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "continuation.resume()" })
    }

    @Test("A resume() that is the sole statement of an implicit-parameter ($0) closure is excluded")
    func resumeAsSoleStatementOfImplicitParameterClosureIsExcluded() throws {
        let source = """
        func completeAll(_ continuations: [CheckedContinuation<Void, Never>?]) {
            continuations.forEach { $0?.resume() }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "$0?.resume()" })
    }

    @Test("resume() assigned to a variable is not a bare statement and is excluded")
    func resumeAssignedToVariableIsExcluded() throws {
        let source = """
        func complete(_ continuation: CheckedContinuation<Void, Never>) {
            let result = continuation.resume()
            use(result)
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "continuation.resume()" })
    }

    @Test("A differently-named method called resume on an unrelated type is still matched (name-only, no symbol resolution)")
    func nameOnlyMatchingIsDocumentedBehavior() throws {
        let source = """
        func poll(_ timer: Timer) {
            log()
            timer.resume()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "timer.resume()" })
    }

    @Test("A call named resumeAll (not exactly resume) is not matched")
    func differentlyNamedMethodIsExcluded() throws {
        let source = """
        func complete(_ continuation: CheckedContinuation<Void, Never>) {
            log()
            continuation.resumeAll()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("resumeAll") })
    }

    // MARK: - Negative scenarios: sole resume() in a continuation-creating closure

    //
    // Found on `apple/swift-nio`'s real corpus (2026-09), not a fixture-only
    // risk: `await withCheckedContinuation { continuation in ... }` infers
    // its generic `Success` type from a `resume`/`resume(returning:)` call
    // reachable in the closure body, when nothing else pins the type.
    // Emptying the closure's only such call fails to typecheck ("generic
    // parameter 'T' could not be inferred"), confirmed directly with a real
    // `swiftc -typecheck` — see
    // `ContinuationResumeRemovalCompileViabilityAcceptanceTests` for that
    // proof.

    @Test("A sole resume() inside withCheckedContinuation's closure is excluded, even nested and not the sole statement")
    func soleResumeInWithCheckedContinuationClosureIsExcluded() throws {
        let source = """
        func advanceTime() async {
            await withCheckedContinuation { continuation in
                self.queue.async {
                    self.doSomething()
                    continuation.resume()
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "continuation.resume()" })
    }

    @Test("A resume() with a sibling resume() elsewhere in the same continuation closure is still a candidate")
    func resumeWithSiblingInSameContinuationClosureIsCandidate() throws {
        let source = """
        func advanceTime(flag: Bool) async {
            await withCheckedContinuation { continuation in
                if flag {
                    continuation.resume()
                } else {
                    continuation.resume()
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.filter { $0.originalText == "continuation.resume()" }.count == 2)
    }

    @Test("A sole resume() inside withUnsafeThrowingContinuation's closure is also excluded")
    func soleResumeInWithUnsafeThrowingContinuationClosureIsExcluded() throws {
        let source = """
        func fetch() async throws -> Int {
            try await withUnsafeThrowingContinuation { continuation in
                continuation.resume(throwing: SomeError.failed)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "continuation.resume(throwing: SomeError.failed)" })
    }

    @Test("A resume() outside any continuation-creating closure is unaffected by the new guard")
    func resumeOutsideContinuationCreatingClosureIsUnaffected() throws {
        let source = """
        final class Box {
            var continuation: CheckedContinuation<Void, Never>?
            func complete() {
                continuation?.resume()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "continuation?.resume()" })
    }

    /// Found by adversarial review (round 2), then confirmed directly with a
    /// real `swiftc -typecheck`: `DispatchSourceTimer`/`DispatchSourceProtocol`
    /// also has a `resume()` method, a real stdlib API that plausibly
    /// co-occurs with a continuation in timeout/cancellation code, and a
    /// same-named call on it must never be mistaken for a second call that
    /// would keep the continuation's own type inference alive. Matching
    /// `resume` by method name alone at this specific point (as opposed to
    /// discovery itself, which matches by name deliberately) would have
    /// under-excluded this exact shape.
    @Test("A same-named resume() on an unrelated receiver does not save the continuation's sole resume() from exclusion")
    func sameNamedResumeOnUnrelatedReceiverDoesNotPreventExclusion() throws {
        let source = """
        func waitForSignal(_ timerSource: DispatchSourceTimer) async {
            await withCheckedContinuation { continuation in
                timerSource.resume()
                continuation.resume()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "continuation.resume()" })
        // The unrelated timerSource.resume() is untouched by this operator's
        // own guard reasoning either way -- it is still name-matched by
        // discovery like any other `resume` call (no symbol resolution), so
        // it remains its own, independent candidate.
        #expect(points.contains { $0.originalText == "timerSource.resume()" })
    }
}
