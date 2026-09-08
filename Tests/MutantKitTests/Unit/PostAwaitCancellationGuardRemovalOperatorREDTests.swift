import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// RED tests for `apple.concurrency.post-await-cancellation-guard-removal`.
/// Positive scenarios prove discovery finds the exact fault shape from
/// `zubair-io/Maple` PR #3018 and `whysasse/verso-app` PR #375; negative
/// scenarios prove each narrowing constraint in the operator's own doc
/// comment actually fires. See
/// `PostAwaitCancellationGuardRemovalCompileViabilityAcceptanceTests` for the
/// direct `swiftc` compile-safety proof this suite's shapes are grounded in.
@Suite("RED: Apple concurrency post-await-cancellation-guard-removal operator")
struct PostAwaitCancellationGuardRemovalOperatorREDTests {
    private let operatorID = "apple.concurrency.post-await-cancellation-guard-removal"

    private static let guardText = "guard !Task.isCancelled else { return }"

    // MARK: - Positive scenarios

    @Test("A post-await cancellation guard (non-throwing await) is a candidate")
    func nonThrowingAwaitIsCandidate() throws {
        let source = """
        func run() async {
            let value = await load()
            guard !Task.isCancelled else { return }
            state = value
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == Self.guardText && $0.replacementText.isEmpty })
    }

    @Test("A post-await cancellation guard (try await) is a candidate")
    func throwingAwaitIsCandidate() throws {
        let source = """
        func run() async throws {
            let value = try await load()
            guard !Task.isCancelled else { return }
            state = value
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == Self.guardText && $0.replacementText.isEmpty })
    }

    @Test("A post-await cancellation guard inside a for loop, after the loop's own await, is a candidate")
    func guardAfterAwaitInsideForLoopIsCandidate() throws {
        // Mirrors zubair-io/Maple PR #3018's MuiRemoteImageController.start(tiers:):
        // `let loaded = try? await loader(url); guard !Task.isCancelled else { return }`
        // inside the tier loop.
        let source = """
        func run(_ xs: [Int]) async {
            for x in xs {
                let loaded = try? await loader(x)
                guard !Task.isCancelled else { return }
                use(loaded)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == Self.guardText })
    }

    @Test("A post-await cancellation guard as the last statement of a switch case is a candidate")
    func guardAsLastStatementOfSwitchCaseIsCandidate() throws {
        let source = """
        func run(_ action: Action) async {
            switch action {
            case .load:
                let v = await load()
                guard !Task.isCancelled else { return }
                state = v
            case .none:
                break
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == Self.guardText })
    }

    @Test("A post-await cancellation guard inside a Task { } closure is a candidate")
    func guardInsideTaskClosureIsCandidate() throws {
        let source = """
        func run() {
            Task {
                let v = await self.load()
                guard !Task.isCancelled else { return }
                self.state = v
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == Self.guardText })
    }

    // MARK: - Negative scenarios

    @Test("A guard whose else body performs cleanup before returning is excluded")
    func guardWithCleanupInElseIsExcluded() throws {
        let source = """
        func run() async {
            let value = await load()
            guard !Task.isCancelled else {
                cleanup()
                return
            }
            state = value
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("Task.isCancelled") })
    }

    @Test("An if-statement form (not a guard) is excluded")
    func ifStatementFormIsExcluded() throws {
        let source = """
        func run() async {
            let value = await load()
            if Task.isCancelled { return }
            state = value
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A guard on a differently-named receiver is excluded")
    func differentReceiverIsExcluded() throws {
        let source = """
        func run() async {
            let value = await load()
            guard !foo.isCancelled else { return }
            state = value
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("No mutation when there is no preceding awaited operation")
    func noPrecedingAwaitIsExcluded() throws {
        let source = """
        func run() async {
            guard !Task.isCancelled else { return }
            state = 1
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A guard with no preceding item at all, inside a for loop, is excluded even though a later sibling guard is not")
    func firstStatementOfLoopBodyIsExcludedButLaterGuardIsNot() throws {
        // Mirrors Maple PR #3018's per-iteration guard placed BEFORE that
        // iteration's own await -- a different, narrower fault (cancelled
        // before work starts) this operator does not target -- alongside the
        // one placed immediately AFTER the await, which this operator does.
        let source = """
        func run(_ xs: [Int]) async {
            for x in xs {
                guard !Task.isCancelled else { return }
                let loaded = try? await loader(x)
                guard !Task.isCancelled else { return }
                use(loaded)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        #expect(points.contains { $0.originalText == Self.guardText })
    }

    @Test("A compound condition is excluded")
    func compoundConditionIsExcluded() throws {
        let source = """
        func run() async {
            let value = await load()
            guard !Task.isCancelled && ready else { return }
            state = value
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A guard with an additional optional-binding condition is excluded")
    func additionalBindingConditionIsExcluded() throws {
        let source = """
        func run() async {
            let value = await load()
            guard !Task.isCancelled, let unwrapped = value else { return }
            state = unwrapped
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A guard that is the first statement of a catch body is excluded, even though it follows a try await that threw")
    func guardAsFirstStatementOfCatchBodyIsExcluded() throws {
        // Mirrors whysasse/verso-app PR #375's own do/catch shape: the `do`
        // block's guard (after its own preceding `try await`) is a
        // candidate, but the `catch` block's guard is not -- it is the
        // first item of the catch body's own list, with no sibling to
        // search for an await in.
        let source = """
        func save(_ url: String) async {
            do {
                let pending = try await parse(url)
                guard !Task.isCancelled else { return }
                state = .success(pending)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failure(error)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly the do-block's guard, got \(points.map(\.originalText))")
        #expect(points.contains { $0.originalText == Self.guardText })
    }

    @Test("A guard whose else body returns a value is excluded")
    func elseReturningAValueIsExcluded() throws {
        let source = """
        func run() async -> Int {
            let value = await load()
            guard !Task.isCancelled else { return -1 }
            return value
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }
}
