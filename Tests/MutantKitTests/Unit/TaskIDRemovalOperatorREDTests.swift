import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// RED tests for `apple.swiftui.task-id-removal`. Positive scenarios prove
/// discovery finds the exact fault shape from `zubair-io/Maple` PR #3018;
/// negative scenarios prove each narrowing constraint in the operator's own
/// doc comment actually fires. See `TaskIDRemovalCompileViabilityAcceptanceTests`
/// for the direct `swiftc` compile-safety proof this suite's shapes are
/// grounded in.
@Suite("RED: Apple SwiftUI task-id-removal operator")
struct TaskIDRemovalOperatorREDTests {
    private let operatorID = "apple.swiftui.task-id-removal"

    // MARK: - Positive scenarios

    @Test("Canonical .task(id:) is a candidate, replaced with plain .task")
    func canonicalTaskIDIsCandidate() throws {
        let source = """
        struct ItemView: View {
            var body: some View {
                view
                    .task(id: item.id) {
                        await reload(item)
                    }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        #expect(point.originalText.contains(".task(id: item.id)"))
        #expect(!point.replacementText.contains("id:"))
        #expect(point.replacementText.contains(".task {"))
        #expect(point.replacementText.contains("await reload(item)"), "the closure body must be preserved byte-for-byte")
    }

    @Test(".task(id:priority:) keeps priority:, drops only id:")
    func taskIDWithPriorityKeepsPriority() throws {
        let source = """
        struct ItemView: View {
            var body: some View {
                view
                    .task(id: item.id, priority: .userInitiated) {
                        await reload(item)
                    }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        #expect(!point.replacementText.contains("id:"))
        #expect(point.replacementText.contains("priority: .userInitiated"))
        #expect(point.replacementText.contains(".task(priority: .userInitiated)"))
        #expect(point.replacementText.contains("await reload(item)"))
    }

    @Test("A multiline id: expression is still recognized")
    func multilineIDExpressionIsCandidate() throws {
        // Mirrors zubair-io/Maple PR #3018's own shape: `tiers.ordered.map(\.1)`.
        let source = """
        struct RemoteImageView: View {
            var body: some View {
                content
                    .task(
                        id: tiers.ordered.map(\\.1)
                    ) {
                        await controller.start(tiers: tiers)
                    }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        #expect(!point.replacementText.contains("id:"))
        #expect(point.replacementText.contains("await controller.start(tiers: tiers)"))
    }

    @Test("A .task(id:) nested deep in a modifier chain is a candidate")
    func nestedModifierChainIsCandidate() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Text(title)
                    .padding()
                    .background(Color.white)
                    .task(id: model.id) {
                        await model.reload()
                    }
                    .accessibilityLabel(title)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
    }

    @Test("Formatting/trivia variation around .task(id:) does not affect discovery")
    func trailingCommentDoesNotAffectDiscovery() throws {
        let source = """
        struct ItemView: View {
            var body: some View {
                view
                    .task(id: item.id) {  // reload on identity change
                        await reload(item)
                    }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1)
    }

    // MARK: - Negative scenarios

    @Test("Plain .task { } with no arguments is not a candidate")
    func plainTaskIsExcluded() throws {
        let source = """
        struct ItemView: View {
            var body: some View {
                view.task { await reload() }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A non-matching argument label is excluded")
    func nonMatchingLabelIsExcluded() throws {
        let source = """
        struct ItemView: View {
            var body: some View {
                view.task(priority: .userInitiated) { await reload() }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("priority: before id: (wrong order) is excluded")
    func wrongArgumentOrderIsExcluded() throws {
        let source = """
        struct ItemView: View {
            var body: some View {
                view.task(priority: .userInitiated, id: item.id) { await reload(item) }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("An unrelated method named task with a different signature is excluded")
    func unrelatedTaskMethodIsExcluded() throws {
        let source = """
        struct Scheduler {
            func run() {
                queue.task(handler: { doWork() })
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A third, unknown argument is excluded")
    func thirdUnknownArgumentIsExcluded() throws {
        let source = """
        struct ItemView: View {
            var body: some View {
                view.task(id: item.id, priority: .userInitiated, extra: true) { await reload(item) }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A call with no trailing closure (explicit closure argument) is excluded")
    func noTrailingClosureIsExcluded() throws {
        let source = """
        struct ItemView: View {
            var body: some View {
                view.task(id: item.id, body: { await reload(item) })
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("The closure body is never mutated, only the argument list")
    func closureBodyIsNeverMutated() throws {
        let source = """
        struct ItemView: View {
            var body: some View {
                view
                    .task(id: item.id) {
                        await reload(item)
                        state = .loaded
                    }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(points.first)
        #expect(point.replacementText.contains("await reload(item)"))
        #expect(point.replacementText.contains("state = .loaded"))
    }
}
