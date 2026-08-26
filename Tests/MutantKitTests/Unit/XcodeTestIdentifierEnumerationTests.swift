@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Pins the walk over `xcresulttool get test-results tests --compact`'s
/// tree against a real captured document (a two-test toy package, built
/// with `xcodebuild test` on Xcode 26.6) — the schema this exists to
/// depend on is undocumented and not guaranteed stable across Xcode
/// releases, so a real fixture catches a shape change a hand-written one
/// would not.
@Suite("Xcode test identifier enumeration")
struct XcodeTestIdentifierEnumerationTests {
    /// Captured verbatim from `xcrun xcresulttool get test-results tests
    /// --path Result.xcresult --compact` against a package with two test
    /// classes (`AddTests`, `SubTests`), one test method each, in a single
    /// `CovProbeTests` bundle.
    private static let capturedDocument = Data("""
    {"devices":[{"architecture":"arm64","deviceId":"00008132-0006196C227A801C","deviceName":"My Mac","modelName":"MacBook Air","osBuildNumber":"25F84","osVersion":"26.5.2","platform":"macOS"}],"testNodes":[{"children":[{"children":[{"children":[{"duration":"0.00094s","durationInSeconds":0.0009419918060302734,"name":"testAdd()","nodeIdentifier":"AddTests/testAdd()","nodeIdentifierURL":"test://com.apple.xcode/CovProbe/CovProbeTests/AddTests/testAdd","nodeType":"Test Case","result":"Passed"}],"name":"AddTests","nodeIdentifierURL":"test://com.apple.xcode/CovProbe/CovProbeTests/AddTests","nodeType":"Test Suite","result":"Passed"},{"children":[{"duration":"0.00045s","durationInSeconds":0.0004520416259765625,"name":"testSub()","nodeIdentifier":"SubTests/testSub()","nodeIdentifierURL":"test://com.apple.xcode/CovProbe/CovProbeTests/SubTests/testSub","nodeType":"Test Case","result":"Passed"}],"name":"SubTests","nodeIdentifierURL":"test://com.apple.xcode/CovProbe/CovProbeTests/SubTests","nodeType":"Test Suite","result":"Passed"}],"name":"CovProbeTests","nodeIdentifierURL":"test://com.apple.xcode/CovProbe/CovProbeTests","nodeType":"Unit test bundle","result":"Passed"}],"name":"CovProbe-Package","nodeType":"Test Plan","result":"Passed"}],"testPlanConfigurations":[{"configurationId":"1","configurationName":"Test Scheme Action"}]}
    """.utf8)

    @Test("Every test case is found, qualified by class, onlyTestingArgument restores the trailing ()")
    func findsEveryTestCase() {
        let found = XcodeBuildAdapter.parseTestIdentifiers(Self.capturedDocument)

        // Phase C13: `onlyTestingArgument` always appends `()` (required
        // for `xcodebuild` to match a Swift Testing `@Test` function via
        // `-only-testing:` at all; tolerated either way for XCTest) --
        // `qualifiedName` itself, asserted separately below, still has no
        // trailing `()`, exactly as documented.
        #expect(Set(found.map(\.onlyTestingArgument)) == [
            "CovProbeTests/AddTests/testAdd()",
            "CovProbeTests/SubTests/testSub()"
        ])
        #expect(Set(found.map(\.qualifiedName)) == [
            "AddTests/testAdd",
            "SubTests/testSub"
        ])
    }

    @Test("Every identifier is attributed to the Unit test bundle ancestor's name, not the test plan's")
    func attributesToTheTestBundleNotThePlan() {
        let found = XcodeBuildAdapter.parseTestIdentifiers(Self.capturedDocument)

        #expect(found.allSatisfy { $0.target == "CovProbeTests" })
        #expect(found.allSatisfy { $0.target != "CovProbe-Package" })
    }

    @Test("Malformed JSON yields no identifiers rather than throwing")
    func malformedJSONYieldsEmpty() {
        #expect(XcodeBuildAdapter.parseTestIdentifiers(Data("not json".utf8)).isEmpty)
    }

    @Test("A document with no testNodes yields no identifiers")
    func noTestNodesYieldsEmpty() {
        #expect(XcodeBuildAdapter.parseTestIdentifiers(Data("{}".utf8)).isEmpty)
    }
}
