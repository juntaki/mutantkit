import MutationModel
import Testing

@Suite("RED: restricted return-value replacement operator")
struct ReturnValueReplacementOperatorREDTests {
    private let operatorID = "swift.core.return-value-replacement"

    @Test("Replaces explicit literal and collection returns with neutral values")
    func replacesSyntaxLocalReturnValues() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func number() -> Int { return 42 }
            func title() -> String { return "ready" }
            func items() -> [Int] { return [1, 2] }
            func mapping() -> [String: Int] { return ["a": 1] }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 4)
        #expect(CoreOperatorExpansionTestSupport.replacementPairs(points) == [
            "42 -> 0",
            "\"ready\" -> \"\"",
            "[1, 2] -> []",
            "[\"a\": 1] -> [:]"
        ])
        #expect(points.allSatisfy { $0.operatorID == operatorID && $0.confidence == .medium })
    }

    @Test("Replaces a value returned from a syntactically optional function with nil")
    func replacesOptionalReturnWithNil() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func lookup(_ cached: Int?) -> Int? {
                return cached
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(points[0].originalText == "cached")
        #expect(points[0].replacementText == "nil")
    }

    @Test("Understands both question-mark and Optional generic return spellings")
    func supportsOptionalReturnSpellings() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func shorthand(_ value: Int?) -> Int? { return value }
            func generic(_ value: String?) -> Optional<String> { return value }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 2)
        #expect(Set(points.map(\.replacementText)) == ["nil"])
    }

    @Test("Does not duplicate bool inversion or replace values that are already neutral")
    func avoidsDuplicateAndEquivalentMutants() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func flag() -> Bool { return true }
            func number() -> Int { return 0 }
            func title() -> String { return "" }
            func items() -> [Int] { return [] }
            func mapping() -> [String: Int] { return [:] }
            func optional() -> Int? { return nil }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("Does not replace an integer literal that is already zero, however it is spelled")
    func doesNotReplaceAlreadyZeroIntegersRegardlessOfRadix() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func hex() -> Int { return 0x0 }
            func binary() -> Int { return 0b0 }
            func octal() -> Int { return 0o0 }
            func underscored() -> Int { return 0_0 }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty, "0x0/0b0/0o0/0_0 are all the same value 0 just spelled differently")
    }

    @Test("Does not replace nil spelled as a cast or as .none with plain nil")
    func doesNotReplaceOtherNilSpellingsWithNil() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func castNil() -> Int? { return nil as Int? }
            func genericNone() -> Int? { return Optional<Int>.none }
            func bareNone() -> Int? { return .none }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty, "`nil as Int?`, `Optional<Int>.none`, and `.none` are all the same value as nil")
    }

    /// A different enum's own `.none` case is not `Optional.none`: returning
    /// `State.none` from a `State?`-returning function wraps it as
    /// `.some(State.none)`, which is not the same runtime value as `nil`.
    /// The previous version of this check excluded ANY `.none` member
    /// access regardless of base, which wrongly treated this as an
    /// already-nil value and skipped it.
    @Test("Replaces a different type's own .none case with nil, since that is not the same value as Optional.none")
    func replacesAnUnrelatedTypesNoneCaseWithNil() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            enum State {
                case none
                case active
            }

            func state() -> State? {
                return State.none
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(points[0].originalText == "State.none")
        #expect(points[0].replacementText == "nil")
    }

    @Test("Does not replace an empty raw string or a whitespace-only empty collection")
    func doesNotReplaceOtherNeutralSpellings() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            #"""
            func rawEmpty() -> String { return #""# }
            func spacedArray() -> [Int] { return [ ] }
            """#,
            operatorID: operatorID
        )

        #expect(points.isEmpty, "an empty raw string and `[ ]` are the same value as \"\" and [] just spelled differently")
    }

    @Test("Does not empty literals merely because they appear outside an explicit return")
    func staysRestrictedToReturnValues() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            let globalNumber = 42
            let globalTitle = "ready"
            let globalItems = [1, 2]

            func number() -> Int {
                let local = 42
                return local + 1
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }
}
