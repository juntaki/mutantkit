import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Properties every operator has to satisfy to be allowed in the default
/// profile, checked against the same fixtures for all of them. An operator that
/// fails one of these produces mutants that are noise at best and corruption at
/// worst, regardless of how good its individual test cases look.
@Suite("Operator contract")
struct OperatorContractTests {
    static let fixtures = ["RealisticViewModel", "UnicodeHeavy"]

    /// A replacement identical to the original compiles to the same binary and
    /// would be reported as a mutant that never mutated anything — a phantom by
    /// construction.
    @Test("No operator proposes a no-op mutation", arguments: fixtures)
    func noNoOpMutations(fixture: String) throws {
        let points = try discover(try Fixture.text(fixture), path: "Sources/\(fixture).swift")

        #expect(!points.isEmpty)
        for point in points {
            #expect(
                point.originalText != point.replacementText,
                "\(point.displayLocation) replaces \(point.originalText) with itself"
            )
        }
    }

    /// Every mutant that does not compile is a mutant that costs a full build
    /// and teaches nothing. The operators here only ever swap a token for
    /// another token of the same syntactic category, so every one of their
    /// outputs must still parse.
    @Test("Every discovered mutation still parses after it is applied", arguments: fixtures)
    func everyMutationCompilesToValidSwift(fixture: String) throws {
        let source = try Fixture.text(fixture)
        let data = Data(source.utf8)
        let points = try discover(source, path: "Sources/\(fixture).swift")

        #expect(!points.isEmpty)
        #expect(parsesWithoutError(data), "the fixture itself must parse")

        for point in points {
            let applied = try MutationApplication.apply(point, to: data)
            #expect(
                parsesWithoutError(applied.mutatedSource),
                "\(point.displayLocation): \(point.originalText) -> \(point.replacementText) does not parse"
            )
        }
    }

    @Test("Every discovered mutation verifies against the source it came from", arguments: fixtures)
    func everyMutationAnchorsToItsSource(fixture: String) throws {
        let source = try Fixture.text(fixture)
        let data = Data(source.utf8)

        for point in try discover(source, path: "Sources/\(fixture).swift") {
            let verification = SourceAnchorVerifier.verify(point, against: data, depth: .full)
            #expect(verification.isValid, "\(point.displayLocation): \(verification.diagnosis)")
        }
    }

    @Test("Every discovered mutation records where it came from", arguments: fixtures)
    func pointsAreSelfDescribing(fixture: String) throws {
        let source = try Fixture.text(fixture)
        let path = "Sources/\(fixture).swift"

        for point in try discover(source, path: path) {
            #expect(point.file == path)
            #expect(point.sourceFileHash == ContentHash.of(Data(source.utf8)))
            #expect(point.line >= 1)
            #expect(point.column >= 1)
            #expect(point.executionMode == .isolated)
            #expect(point.utf8Range.length > 0)
            #expect(!point.originalText.isEmpty)
            #expect(!point.replacementText.isEmpty)
        }
    }

    @Test("Both shipped operators declare the metadata a report needs", arguments: [
        BoolLiteralInversionOperator.descriptor,
        RelationalOperatorReplacementOperator.descriptor
    ])
    func descriptorsAreComplete(descriptor: OperatorDescriptor) {
        #expect(descriptor.id.hasPrefix("swift.core."))
        #expect(descriptor.version >= 1)
        #expect(!descriptor.summary.isEmpty)
        #expect(!descriptor.category.isEmpty)
        // Every operator must earn schemata eligibility by passing a
        // differential test against isolated execution; none is grandfathered in.
        #expect(!descriptor.schemataEligible)
        #expect(!descriptor.requiresSymbolResolution)
        // An operator with no justification produces mutants nobody can act on.
        #expect(!descriptor.faultEvidence.isEmpty)
    }

    @Test("The conservative profile admits both v0.1 operators")
    func profileAdmitsShippedOperators() {
        for descriptor in [
            BoolLiteralInversionOperator.descriptor,
            RelationalOperatorReplacementOperator.descriptor
        ] {
            #expect(OperatorProfile.conservative.admits(descriptor))
            #expect(OperatorProfile.default.admits(descriptor))
            #expect(OperatorProfile.experimental.admits(descriptor))
        }
    }

    /// An operator that could raise its own sites' confidence would make
    /// `--profile conservative` meaningless. Overrides may only narrow.
    @Test("Discovered confidence never exceeds the operator's declared confidence", arguments: fixtures)
    func confidenceIsNeverWidened(fixture: String) throws {
        let descriptors = [
            BoolLiteralInversionOperator.descriptor.id: BoolLiteralInversionOperator.descriptor,
            RelationalOperatorReplacementOperator.descriptor.id: RelationalOperatorReplacementOperator.descriptor
        ]

        for point in try discover(try Fixture.text(fixture), path: "Sources/\(fixture).swift") {
            let declared = try #require(descriptors[point.operatorID]).confidence
            #expect(point.confidence <= declared)
        }
    }

    // MARK: - Known defect

    /// `OperatorExclusions` intends to skip `#if` *conditions*, on the grounds
    /// that mutating one compiles a different program rather than testing the
    /// suite. But the exclusion walks the ancestor chain for
    /// `IfConfigClauseSyntax`, and that node holds the clause *body* as well as
    /// its condition — so every declaration inside any `#if` block is silently
    /// dropped from discovery.
    ///
    /// For an iOS codebase that is a large hole: `#if DEBUG`, `#if os(iOS)` and
    /// `#if canImport(UIKit)` routinely guard real, testable logic, and none of
    /// it is currently mutated. The exclusion needs to fire only when the node
    /// lies within the clause's `condition`.
    @Test("Code inside an #if body is mutated, unlike the #if condition itself")
    func ifConfigBodiesShouldStillBeMutated() throws {
        let points = try discover("""
        #if DEBUG
        let verbose = true
        #endif
        """)

        #expect(points.count == 1)
        #expect(points.first?.originalText == "true")
    }

    @Test("Comparisons inside an #if body are mutated")
    func ifConfigBodiesWithComparisonsShouldStillBeMutated() throws {
        let points = try discover("""
        #if os(iOS)
        func isOverLimit(_ count: Int) -> Bool { count > 10 }
        #endif
        """, using: Operators.relational)

        #expect(points.count == 2)
    }
}
