@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

@Suite("Coverage granularity")
struct CoverageGranularityTests {
    private func test(_ qualifiedName: String, target: String = "AppTests") -> TestIdentifier {
        TestIdentifier(target: target, qualifiedName: qualifiedName)
    }

    private func matches(_ filter: String, _ identifier: String) throws -> Bool {
        try NSRegularExpression(pattern: filter).firstMatch(
            in: identifier, range: NSRange(identifier.startIndex..., in: identifier)
        ) != nil
    }

    @Test("The setting defaults to test and decodes suite")
    func settingDecodes() throws {
        #expect(ExecutionSettings().coverageGranularity == .test)
        let empty = try JSONDecoder().decode(ExecutionSettings.self, from: Data("{}".utf8))
        #expect(empty.coverageGranularity == .test)
        let suite = try JSONDecoder().decode(ExecutionSettings.self, from: Data(#"{"coverageGranularity": "suite"}"#.utf8))
        #expect(suite.coverageGranularity == .suite)
    }

    @Test("The default is left out of the encoding, so every existing configurationHash is unchanged")
    func defaultIsNotEncoded() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let byDefault = try String(decoding: encoder.encode(ExecutionSettings()), as: UTF8.self)
        #expect(!byDefault.contains("coverageGranularity"))

        let suite = try String(decoding: encoder.encode(ExecutionSettings(coverageGranularity: .suite)), as: UTF8.self)
        #expect(suite.contains(#""coverageGranularity":"suite""#))

        let roundTripped = try JSONDecoder().decode(ExecutionSettings.self, from: Data(suite.utf8))
        #expect(roundTripped.coverageGranularity == .suite)
    }

    @Test("Per-test granularity measures each test alone, as before")
    func testGranularityIsUnchanged() throws {
        let one = test("AddTests/testAdd()")
        let sizes = SwiftPackageMacOSAdapter.suiteSizes(of: [one])
        let unit = SwiftPackageMacOSAdapter.coverageUnit(for: one, granularity: .test, suiteSizes: sizes)

        #expect(try matches(unit.filter, "AppTests.AddTests/testAdd()"))
        #expect(try !matches(unit.filter, "AppTests.AddTests/testSubtract()"))
        #expect(unit.expectedTestCount == 1)
        #expect(unit.suiteKey == nil)
    }

    @Test("Suite granularity runs a suite once, expecting as many tests as it holds")
    func suiteGranularityGroupsTests() throws {
        let tests = [
            test("AddTests/testAdd()"), test("AddTests/testSubtract()"), test("AddTests/testNegate()"),
            test("OtherTests/testOther()")
        ]
        let sizes = SwiftPackageMacOSAdapter.suiteSizes(of: tests)
        #expect(sizes == ["AppTests.AddTests": 3, "AppTests.OtherTests": 1])

        let units = tests.map { SwiftPackageMacOSAdapter.coverageUnit(for: $0, granularity: .suite, suiteSizes: sizes) }
        #expect(Set(units.prefix(3)).count == 1, "every test of one suite shares one unit")
        #expect(units[0] != units[3])
        #expect(units[0].suiteKey == "AppTests.AddTests")
        #expect(units[0].expectedTestCount == 3)

        #expect(try matches(units[0].filter, "AppTests.AddTests/testNegate()"))
        #expect(try !matches(units[0].filter, "AppTests.OtherTests/testOther()"))
        #expect(try !matches(units[0].filter, "AppTests.AddTestsExtra/testAdd()"), "a suite whose name starts the same is not it")
    }

    @Test("A nested suite belongs to its top-level suite, whose one filter selects all of it")
    func nestedSuitesBelongToTheirParent() throws {
        let tests = [test("Outer/testA()"), test("Outer/Inner/testB()"), test("Outer/Inner/testC()")]
        let sizes = SwiftPackageMacOSAdapter.suiteSizes(of: tests)
        #expect(sizes == ["AppTests.Outer": 3])

        let units = tests.map { SwiftPackageMacOSAdapter.coverageUnit(for: $0, granularity: .suite, suiteSizes: sizes) }
        #expect(Set(units).count == 1)
        #expect(units[0].expectedTestCount == 3)
        for identifier in ["AppTests.Outer/testA()", "AppTests.Outer/Inner/testB()", "AppTests.Outer/Inner/testC()"] {
            #expect(try matches(units[0].filter, identifier))
        }
    }

    @Test("The filter avoids a negated character class, which SwiftPM's --filter never matches")
    func filterUsesNoNegatedClass() {
        let tests = [test("AddTests/testAdd()")]
        let unit = SwiftPackageMacOSAdapter.coverageUnit(
            for: tests[0], granularity: .suite, suiteSizes: SwiftPackageMacOSAdapter.suiteSizes(of: tests)
        )
        #expect(!unit.filter.contains("[^"))
    }

    @Test("A run that only fell short because every selected test was skipped is recognised")
    func allSkippedIsRecognised() {
        typealias Adapter = SwiftPackageMacOSAdapter
        #expect(Adapter.allSelectedTestsSkipped(skippedCount: 3, expectedTestCount: 3))
        #expect(!Adapter.allSelectedTestsSkipped(skippedCount: 2, expectedTestCount: 3), "one was not skipped")
        #expect(!Adapter.allSelectedTestsSkipped(skippedCount: 0, expectedTestCount: 3))
        #expect(!Adapter.allSelectedTestsSkipped(skippedCount: 3, expectedTestCount: nil))
        #expect(!Adapter.allSelectedTestsSkipped(skippedCount: nil, expectedTestCount: 3))
    }

    @Test("The skipped count is read from a Swift Testing report that lists the test under a suite counting none")
    func skippedCountIsReadFromTheReport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-xunit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites>
            <testsuite name="TestResults" errors="0" tests="0" failures="0" skipped="1" time="0.0002">
                <testcase classname="AlphaTests.DisabledAlphaTests" name="neverRuns()"><skipped>why</skipped></testcase>
            </testsuite>
        </testsuites>
        """
        let requested = directory.appendingPathComponent("run.xml")
        try report.write(to: directory.appendingPathComponent("run-swift-testing.xml"), atomically: true, encoding: .utf8)
        #expect(XUnitParser.swiftTestingSkippedCount(forRequestedOutput: requested) == 1)
    }

    @Test("An XCTest-shaped suite is run whole but its test count is left unchecked")
    func xctestCountIsNotChecked() {
        let tests = [test("AddTests/testAdd"), test("AddTests/testSubtract")]
        let sizes = SwiftPackageMacOSAdapter.suiteSizes(of: tests)
        let unit = SwiftPackageMacOSAdapter.coverageUnit(for: tests[0], granularity: .suite, suiteSizes: sizes)
        #expect(unit.suiteKey == "AppTests.AddTests")
        #expect(unit.expectedTestCount == nil)
    }
}
