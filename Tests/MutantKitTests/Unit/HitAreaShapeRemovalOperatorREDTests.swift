import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// RED tests for `apple.swiftui.hit-area-shape-removal`. Split into two
/// suites (positive/negative) purely to stay under SwiftLint's
/// `type_body_length`; both share the same operator ID and fault-shape
/// provenance described here. Positive scenarios prove discovery finds the
/// exact fault shape described in this operator's own doc comment
/// (cashubtc/wallet PR #305 / cwharris77/depth PR #476); negative scenarios
/// prove the Button-ancestry + exact-Rectangle-argument matcher rejects
/// every excluded shape named by the task's own point 6. See
/// `HitAreaShapeRemovalCompileViabilityAcceptanceTests` for the direct
/// `swiftc` compile-safety proof this suite's shapes are grounded in.
@Suite("RED: Apple SwiftUI hit-area-shape-removal operator, positive scenarios")
struct HitAreaShapeRemovalOperatorPositiveREDTests {
    private let operatorID = "apple.swiftui.hit-area-shape-removal"

    @Test("Canonical Button label: HStack { Text; Spacer; Text }.contentShape(Rectangle()) is one candidate")
    func canonicalButtonLabelIsCandidate() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        #expect(point.originalText.contains(".contentShape(Rectangle())"))
        #expect(!point.replacementText.contains("contentShape"))
    }

    @Test("Chained form: .padding(), .contentShape(Rectangle()), .frame(maxWidth:) — rest of chain preserved")
    func chainedFormPreservesRestOfChain() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                    }
                    .padding()
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity)
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        #expect(point.originalText.contains(".contentShape(Rectangle())"))
        // `.frame(...)` follows the matched call in the chain, so it is not
        // part of this node's own text at all (mirrors
        // ExplicitLabelRemovalOperator's "chained modifier" RED test).
        #expect(!point.originalText.contains(".frame"))
        // `.padding()` precedes the matched call, so it is part of the
        // receiver being preserved -- carried into the replacement text
        // unmodified.
        #expect(point.replacementText.contains(".padding()"))
        #expect(!point.replacementText.contains("contentShape"))
    }

    @Test("Multiline Rectangle() formatting is still a candidate")
    func multilineRectangleFormattingIsCandidate() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                    }
                    .contentShape(
                        Rectangle()
                    )
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
    }

    @Test("Labeled-argument Button(action:label:) form is a candidate")
    func labeledArgumentButtonFormIsCandidate() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button(action: { select() }, label: {
                    HStack {
                        Text(name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                })
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
    }

    @Test("A .contentShape(Rectangle()) nested inside an intermediate VStack, still inside the Button label, is a candidate")
    func nestedInsideIntermediateContainerIsCandidate() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    VStack {
                        HStack {
                            Text(name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
    }

    @Test("Single-trailing-closure Button(action:) form -- the closure is the label since action: is already supplied -- is a candidate")
    func actionArgumentSingleTrailingClosureFormIsCandidate() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button(action: onAccountTap) {
                    Image(systemName: "person.crop.circle")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
    }

    @Test(".contentShape(Rectangle()) chained directly onto the Button call's own result (outside the label closure) is a candidate")
    func chainedDirectlyOntoButtonCallIsCandidate() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    onChange(option.value)
                } label: {
                    Text(option.label)
                }
                .contentShape(Rectangle())
                .buttonStyle(.plain)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        // `.buttonStyle(.plain)` follows the matched call, so it is not part
        // of this node's own text.
        #expect(!point.originalText.contains("buttonStyle"))
    }
}

@Suite("RED: Apple SwiftUI hit-area-shape-removal operator, negative scenarios")
struct HitAreaShapeRemovalOperatorNegativeREDTests {
    private let operatorID = "apple.swiftui.hit-area-shape-removal"

    @Test(".contentShape(Circle()) is excluded")
    func circleShapeIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    HStack { Text(name) }
                        .contentShape(Circle())
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test(".contentShape(RoundedRectangle(cornerRadius: 8)) is excluded")
    func roundedRectangleShapeIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    HStack { Text(name) }
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test(".contentShape(Capsule()) is excluded")
    func capsuleShapeIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    HStack { Text(name) }
                        .contentShape(Capsule())
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("An unrelated .shape(Rectangle()) modifier is excluded")
    func unrelatedShapeModifierIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    HStack { Text(name) }
                        .shape(Rectangle())
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("The eoFill: overload is excluded (not the exact single-argument shape)")
    func eoFillOverloadIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    HStack { Text(name) }
                        .contentShape(Rectangle(), eoFill: true)
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("The ContentShapeKinds-taking overload (drag preview) is excluded")
    func contentShapeKindsOverloadIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    HStack { Text(name) }
                        .contentShape(.dragPreview, Rectangle())
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A .contentShape(Rectangle()) on a decorative view with no Button ancestor at all is excluded")
    func noButtonAncestorIsExcluded() throws {
        let source = """
        struct DecorativeRow: View {
            var body: some View {
                HStack {
                    Text("Decor")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A .contentShape(Rectangle()) inside a Button's action closure (not its label) is excluded")
    func actionClosureIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    HStack { Text("x") }.contentShape(Rectangle())
                    select()
                } label: {
                    Text("Go")
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A bare Button { action } single trailing closure with no action: argument is the action body, not the label -- excluded")
    func bareSingleTrailingClosureWithNoActionArgumentIsExcluded() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    HStack { Text("x") }.contentShape(Rectangle())
                    select()
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("No duplicate candidate is produced for a single modifier call")
    func noDuplicateCandidateForSingleCall() throws {
        let source = """
        struct RowView: View {
            var body: some View {
                Button {
                    select()
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding()
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1)
    }

    @Test("Two independent Button rows each contribute exactly one candidate")
    func twoIndependentButtonRowsEachContributeOneCandidate() throws {
        let source = """
        struct ListView: View {
            var body: some View {
                VStack {
                    Button {
                        selectFirst()
                    } label: {
                        HStack { Text("A"); Spacer() }
                            .contentShape(Rectangle())
                    }
                    Button {
                        selectSecond()
                    } label: {
                        HStack { Text("B"); Spacer() }
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 2, "expected exactly two candidates, got \(points.map(\.originalText))")
    }
}
