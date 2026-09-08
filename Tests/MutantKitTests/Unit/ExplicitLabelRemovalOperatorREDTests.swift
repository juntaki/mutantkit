import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// RED tests for `apple.accessibility.explicit-label-removal`. Positive
/// scenarios prove discovery finds the exact fault shape described in this
/// operator's own doc comment (RevenueCat PR #7357 / Element X PR #5890);
/// negative scenarios prove the exact-name-match matcher rejects every
/// excluded shape named by the task's own point 6. See
/// `ExplicitLabelRemovalCompileViabilityAcceptanceTests` for the direct
/// `swiftc` compile-safety proof this suite's shapes are grounded in.
@Suite("RED: Apple accessibility explicit-label-removal operator")
struct ExplicitLabelRemovalOperatorREDTests {
    private let operatorID = "apple.accessibility.explicit-label-removal"

    // MARK: - Positive scenarios

    @Test("Canonical chain: .accessibilityLabel(\"Close\") is replaced with its receiver")
    func canonicalChainIsCandidate() throws {
        let source = """
        struct CloseButton: View {
            var body: some View {
                Button("Close") {}
                    .accessibilityLabel("Close")
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        #expect(point.originalText.contains(".accessibilityLabel(\"Close\")"))
        #expect(!point.replacementText.contains("accessibilityLabel"))
        #expect(point.replacementText.contains("Button(\"Close\") {}"))
    }

    @Test("Closure-return form: deleting the whole statement would be compile-invalid, so only the receiver is kept")
    func closureReturnFormIsCandidate() throws {
        let source = """
        func apply(_ label: String?, _ transform: (View, String) -> View) -> some View {
            transform(view, label ?? "")
        }

        let result = apply(maybeLabel) { view, label in
            view.accessibilityLabel(label)
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        #expect(point.originalText == "view.accessibilityLabel(label)")
        #expect(point.replacementText == "view")
    }

    @Test("Chained modifier: .accessibilityLabel(label).frame(...) removes only the label call")
    func chainedModifierIsCandidate() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                view
                    .accessibilityLabel(label)
                    .frame(maxWidth: .infinity)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        #expect(point.originalText.contains(".accessibilityLabel(label)"))
        #expect(!point.originalText.contains(".frame"))
        #expect(point.replacementText == "view")
    }

    @Test("Text(...) argument form is a candidate")
    func textArgumentFormIsCandidate() throws {
        let source = """
        struct CloseButton: View {
            var body: some View {
                Button("Close") {}
                    .accessibilityLabel(Text("Close"))
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        #expect(point.originalText.contains(".accessibilityLabel(Text(\"Close\"))"))
    }

    @Test("A .accessibilityLabel(...) nested deep in a modifier chain is a candidate, exactly once")
    func nestedModifierChainIsCandidate() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Text(title)
                    .padding()
                    .background(Color.white)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("row")
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
    }

    // MARK: - Negative scenarios

    @Test("UIKit-style property assignment is never a candidate")
    func uikitPropertyAssignmentIsExcluded() throws {
        let source = """
        final class CloseButtonController {
            func configure(_ button: UIButton) {
                button.accessibilityLabel = "Close"
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test(".accessibilityHint(...) is excluded")
    func accessibilityHintIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                view.accessibilityHint("Double tap to close")
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test(".accessibilityValue(...) is excluded")
    func accessibilityValueIsExcluded() throws {
        let source = """
        struct SliderRow: View {
            var body: some View {
                view.accessibilityValue("50%")
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test(".accessibilityIdentifier(...) is excluded")
    func accessibilityIdentifierIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                view.accessibilityIdentifier("closeButton")
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test(".accessibilityAddTraits(...) / .accessibilityRemoveTraits(...) are excluded")
    func accessibilityTraitsAreExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                view
                    .accessibilityAddTraits(.isButton)
                    .accessibilityRemoveTraits(.isImage)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test(".accessibilityElement(...) / .accessibilityHidden(...) are excluded")
    func accessibilityElementAndHiddenAreExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                view
                    .accessibilityElement(children: .combine)
                    .accessibilityHidden(true)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("An identifier merely containing the substring accessibilityLabel is excluded")
    func nameAlikeSubstringIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                view.myAccessibilityLabelHelper("Close")
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A bare, unqualified accessibilityLabel(...) call with no receiver is excluded")
    func bareCallWithNoReceiverIsExcluded() throws {
        let source = """
        func helper() {
            accessibilityLabel("Close")
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("No duplicate candidate is produced for a single modifier call")
    func noDuplicateCandidateForSingleCall() throws {
        let source = """
        struct CloseButton: View {
            var body: some View {
                Button("Close") {}
                    .accessibilityLabel("Close")
                    .padding()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1)
    }

    @Test("Trivia/formatting variation does not affect discovery or the preserved receiver text")
    func triviaVariationDoesNotAffectDiscovery() throws {
        let source = """
        struct CloseButton: View {
            var body: some View {
                Button("Close") {}
                    .accessibilityLabel(  // explicit name for VoiceOver
                        "Close"
                    )
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1)
        let point = try #require(points.first)
        #expect(point.replacementText == "Button(\"Close\") {}")
    }
}
