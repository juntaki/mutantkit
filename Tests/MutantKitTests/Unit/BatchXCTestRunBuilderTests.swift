@testable import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import Testing

/// `BatchXCTestRunBuilder`'s pure merge — v1-shaped test target dictionaries
/// in, one v2 batch document out. No disk access, no toolchain.
@Suite("Batch xctestrun builder")
struct BatchXCTestRunBuilderTests {
    private static func target(bundle: String) -> [String: Any] {
        ["BlueprintName": bundle, "TestBundlePath": "__TESTROOT__/\(bundle).xctest"]
    }

    @Test("Each item becomes its own named TestConfigurations entry")
    func eachItemBecomesItsOwnConfiguration() {
        let document = BatchXCTestRunBuilder.merge([
            (configurationName: "mut_001", testTargets: [Self.target(bundle: "FooTests")]),
            (configurationName: "mut_002", testTargets: [Self.target(bundle: "FooTests")])
        ])

        let configurations = document["TestConfigurations"] as? [[String: Any]]
        #expect(configurations?.count == 2)
        #expect(configurations?.map { $0["Name"] as? String } == ["mut_001", "mut_002"])
    }

    @Test("Every configuration is enabled")
    func everyConfigurationIsEnabled() {
        let document = BatchXCTestRunBuilder.merge([
            (configurationName: "mut_001", testTargets: [Self.target(bundle: "FooTests")])
        ])
        let configurations = document["TestConfigurations"] as? [[String: Any]]
        #expect(configurations?.allSatisfy { $0["IsEnabled"] as? Bool == true } == true)
    }

    @Test("The document declares format version 2")
    func declaresFormatVersion2() {
        let document = BatchXCTestRunBuilder.merge([])
        let metadata = document["__xctestrun_metadata__"] as? [String: Any]
        #expect(metadata?["FormatVersion"] as? Int == 2)
    }

    @Test("A configuration keeps the test targets it was given, unmodified")
    func keepsTestTargetsUnmodified() {
        let target = Self.target(bundle: "FooTests")
        let document = BatchXCTestRunBuilder.merge([
            (configurationName: "mut_001", testTargets: [target])
        ])
        let configurations = document["TestConfigurations"] as? [[String: Any]]
        let targets = configurations?.first?["TestTargets"] as? [[String: Any]]
        #expect(targets?.first?["BlueprintName"] as? String == "FooTests")
    }

    @Test("An empty item list still produces a well-formed, empty batch")
    func emptyListProducesWellFormedDocument() {
        let document = BatchXCTestRunBuilder.merge([])
        #expect((document["TestConfigurations"] as? [[String: Any]])?.isEmpty == true)
    }

    // MARK: - testTargets(fromV1:)

    @Test("Every non-metadata top-level entry of a v1 xctestrun is treated as a test target")
    func extractsEveryNonMetadataEntry() {
        let v1: [String: Any] = [
            "FooTests": Self.target(bundle: "FooTests"),
            "BarTests": Self.target(bundle: "BarTests"),
            "__xctestrun_metadata__": ["FormatVersion": 1]
        ]
        let targets = BatchXCTestRunBuilder.testTargets(fromV1: v1)
        #expect(Set(targets.map(\.name)) == ["FooTests", "BarTests"])
        #expect(Set(targets.map { $0.target["BlueprintName"] as? String }) == ["FooTests", "BarTests"])
    }

    @Test("__xctestrun_metadata__ itself is never treated as a test target")
    func metadataIsExcluded() {
        let v1: [String: Any] = ["__xctestrun_metadata__": ["FormatVersion": 1]]
        #expect(BatchXCTestRunBuilder.testTargets(fromV1: v1).isEmpty)
    }

    /// Real-world regression: a project with no checked-in `.xcscheme` (Xcode
    /// falls back to an autocreated one) produces this shape instead of the
    /// flat v1 one — confirmed against a real project whose `.xcodeproj` is
    /// entirely gitignored, so a fresh clone never has a scheme file. Treating
    /// every non-metadata top-level Dict as a target (the old, v1-only logic)
    /// would have misread `TestPlan`/`ContainerInfo` here as bogus targets
    /// instead of recognizing `TestConfigurations` at all.
    @Test("A TestConfigurations-shaped xctestrun (no checked-in scheme) is read correctly")
    func extractsFromTestConfigurationsShape() {
        let v2: [String: Any] = [
            "TestConfigurations": [
                [
                    "Name": "Test Scheme Action",
                    "TestTargets": [Self.target(bundle: "FooTests")]
                ]
            ],
            "TestPlan": ["Name": "SampleApp"],
            "ContainerInfo": ["ContainerName": "SampleApp"],
            "__xctestrun_metadata__": ["FormatVersion": 2]
        ]
        let targets = BatchXCTestRunBuilder.testTargets(fromV1: v2)
        #expect(targets.map(\.name) == ["FooTests"])
    }

    @Test("Multiple TestConfigurations entries, and multiple targets within one, all fold in")
    func extractsAllTargetsAcrossConfigurationsAndWithinOne() {
        let v2: [String: Any] = [
            "TestConfigurations": [
                ["Name": "A", "TestTargets": [Self.target(bundle: "FooTests"), Self.target(bundle: "FooUITests")]],
                ["Name": "B", "TestTargets": [Self.target(bundle: "BarTests")]]
            ]
        ]
        let targets = BatchXCTestRunBuilder.testTargets(fromV1: v2)
        #expect(Set(targets.map(\.name)) == ["FooTests", "FooUITests", "BarTests"])
    }

    @Test("A TestConfigurations target's name prefers BlueprintName, falling back to ProductModuleName")
    func testConfigurationsNameFallsBackToProductModuleName() {
        let v2: [String: Any] = [
            "TestConfigurations": [
                [
                    "Name": "A",
                    "TestTargets": [
                        ["BlueprintName": "FooTests", "ProductModuleName": "Foo_Tests"],
                        ["ProductModuleName": "BarTests"]
                    ]
                ]
            ]
        ]
        let targets = BatchXCTestRunBuilder.testTargets(fromV1: v2)
        #expect(Set(targets.map(\.name)) == ["FooTests", "BarTests"])
    }

    // MARK: - build(items:) — the disk-reading half

    @Test("Reading a nonexistent xctestrun throws .unreadable rather than crashing")
    func unreadableXCTestRunThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-no-such-\(UUID().uuidString).xctestrun")

        #expect(throws: BatchXCTestRunError.self) {
            _ = try BatchXCTestRunBuilder.build(items: [
                BatchTestItem(configurationName: "mut_001", xctestrunPath: missing, onlyTestingIdentifiers: nil)
            ])
        }
    }

    @Test("A narrowed item's OnlyTestIdentifiers overrides whatever the source xctestrun had, scoped to its own target")
    func narrowingOverridesOnlyTestIdentifiers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let v1: [String: Any] = [
            "FooTests": Self.target(bundle: "FooTests"),
            "__xctestrun_metadata__": ["FormatVersion": 1]
        ]
        let xctestrunPath = dir.appendingPathComponent("Foo.xctestrun")
        let data = try PropertyListSerialization.data(fromPropertyList: v1, format: .xml, options: 0)
        try data.write(to: xctestrunPath)

        let batchData = try BatchXCTestRunBuilder.build(items: [
            BatchTestItem(
                configurationName: "mut_001", xctestrunPath: xctestrunPath,
                onlyTestingIdentifiers: [TestIdentifier(target: "FooTests", qualifiedName: "SomeClass/testSomething")]
            )
        ])
        let batch = try PropertyListSerialization.propertyList(from: batchData, format: nil) as? [String: Any]
        let configurations = batch?["TestConfigurations"] as? [[String: Any]]
        let target = (configurations?.first?["TestTargets"] as? [[String: Any]])?.first
        #expect(target?["OnlyTestIdentifiers"] as? [String] == ["SomeClass/testSomething"])
    }

    /// Reproduces, at the unit level, the real failure a direct `xcodebuild`
    /// repro against a live simulator confirmed: giving a UI test bundle an
    /// `OnlyTestIdentifiers` filter matching none of its own tests does not
    /// cleanly report zero tests — it reliably fails the bundle's runner to
    /// initialize (`Timed out waiting for AX loaded notification`). A v1
    /// xctestrun folding in a bundle the selection has no tests for must
    /// therefore drop that bundle from the batch configuration entirely,
    /// the same way `-only-testing:<other target>/...` already omits it at
    /// the `xcodebuild` command-line level for a non-batched run.
    @Test("A target with none of the selection's tests is dropped from the configuration, not narrowed to empty")
    func targetWithNoSelectedTestsIsDropped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let v1: [String: Any] = [
            "FooTests": Self.target(bundle: "FooTests"),
            "FooUITests": Self.target(bundle: "FooUITests"),
            "__xctestrun_metadata__": ["FormatVersion": 1]
        ]
        let xctestrunPath = dir.appendingPathComponent("Foo.xctestrun")
        let data = try PropertyListSerialization.data(fromPropertyList: v1, format: .xml, options: 0)
        try data.write(to: xctestrunPath)

        let batchData = try BatchXCTestRunBuilder.build(items: [
            BatchTestItem(
                configurationName: "mut_001", xctestrunPath: xctestrunPath,
                onlyTestingIdentifiers: [TestIdentifier(target: "FooTests", qualifiedName: "SomeClass/testSomething")]
            )
        ])
        let batch = try PropertyListSerialization.propertyList(from: batchData, format: nil) as? [String: Any]
        let configurations = batch?["TestConfigurations"] as? [[String: Any]]
        let targets = configurations?.first?["TestTargets"] as? [[String: Any]]

        #expect(targets?.count == 1)
        #expect(targets?.first?["BlueprintName"] as? String == "FooTests")
    }

    @Test("build(items:) narrows correctly from a TestConfigurations-shaped source xctestrun")
    func buildNarrowsFromTestConfigurationsShapedSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let v2: [String: Any] = [
            "TestConfigurations": [
                ["Name": "Test Scheme Action", "TestTargets": [Self.target(bundle: "FooTests")]]
            ],
            "TestPlan": ["Name": "Foo"],
            "__xctestrun_metadata__": ["FormatVersion": 2]
        ]
        let xctestrunPath = dir.appendingPathComponent("Foo.xctestrun")
        let data = try PropertyListSerialization.data(fromPropertyList: v2, format: .xml, options: 0)
        try data.write(to: xctestrunPath)

        let batchData = try BatchXCTestRunBuilder.build(items: [
            BatchTestItem(
                configurationName: "mut_001", xctestrunPath: xctestrunPath,
                onlyTestingIdentifiers: [TestIdentifier(target: "FooTests", qualifiedName: "SomeClass/testSomething")]
            )
        ])
        let batch = try PropertyListSerialization.propertyList(from: batchData, format: nil) as? [String: Any]
        let configurations = batch?["TestConfigurations"] as? [[String: Any]]
        let target = (configurations?.first?["TestTargets"] as? [[String: Any]])?.first
        #expect(target?["OnlyTestIdentifiers"] as? [String] == ["SomeClass/testSomething"])
    }

    @Test("Selected tests split across two targets narrow each target independently")
    func selectionSplitAcrossTargetsNarrowsEachIndependently() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let v1: [String: Any] = [
            "FooTests": Self.target(bundle: "FooTests"),
            "FooUITests": Self.target(bundle: "FooUITests"),
            "__xctestrun_metadata__": ["FormatVersion": 1]
        ]
        let xctestrunPath = dir.appendingPathComponent("Foo.xctestrun")
        let data = try PropertyListSerialization.data(fromPropertyList: v1, format: .xml, options: 0)
        try data.write(to: xctestrunPath)

        let batchData = try BatchXCTestRunBuilder.build(items: [
            BatchTestItem(
                configurationName: "mut_001", xctestrunPath: xctestrunPath,
                onlyTestingIdentifiers: [
                    TestIdentifier(target: "FooTests", qualifiedName: "SomeClass/testSomething"),
                    TestIdentifier(target: "FooUITests", qualifiedName: "SomeUICase/testTapsButton")
                ]
            )
        ])
        let batch = try PropertyListSerialization.propertyList(from: batchData, format: nil) as? [String: Any]
        let configurations = batch?["TestConfigurations"] as? [[String: Any]]
        let targets = configurations?.first?["TestTargets"] as? [[String: Any]]
        let byName = Dictionary(uniqueKeysWithValues: (targets ?? []).compactMap { target -> (String, [String: Any])? in
            (target["BlueprintName"] as? String).map { ($0, target) }
        })

        #expect(targets?.count == 2)
        #expect(byName["FooTests"]?["OnlyTestIdentifiers"] as? [String] == ["SomeClass/testSomething"])
        #expect(byName["FooUITests"]?["OnlyTestIdentifiers"] as? [String] == ["SomeUICase/testTapsButton"])
    }

    @Test("A configuration whose selection matches no target at all throws rather than silently running everything")
    func selectionMatchingNoTargetThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let v1: [String: Any] = [
            "FooTests": Self.target(bundle: "FooTests"),
            "__xctestrun_metadata__": ["FormatVersion": 1]
        ]
        let xctestrunPath = dir.appendingPathComponent("Foo.xctestrun")
        let data = try PropertyListSerialization.data(fromPropertyList: v1, format: .xml, options: 0)
        try data.write(to: xctestrunPath)

        #expect(throws: BatchXCTestRunError.self) {
            _ = try BatchXCTestRunBuilder.build(items: [
                BatchTestItem(
                    configurationName: "mut_001", xctestrunPath: xctestrunPath,
                    onlyTestingIdentifiers: [TestIdentifier(target: "SomeOtherTarget", qualifiedName: "X/testY")]
                )
            ])
        }
    }
}
