import Foundation
import MutationModel
import Testing

/// The JSON Schema is hand-maintained in code next to `Configuration`, so the
/// two can drift: a newly-added public setting is `Codable` and decodes, but
/// never appears in `mutantkit config --schema`, so editors and CI lose it.
///
/// These tests refuse that drift. Every `Codable` key a fully-populated
/// settings struct can encode must be present in the schema's `properties`,
/// section by section — including nested objects (`execution.budget`,
/// `timeouts.mutant`). Adding a public setting now requires adding it to the
/// schema in the same change, or this suite fails.
@Suite("Configuration schema parity")
struct ConfigurationSchemaParityTests {
    private var schema: [String: Any] {
        get throws {
            let data = Data(ConfigurationJSONSchema.document.utf8)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    @Test("The schema's top-level keys match Configuration exactly")
    func topLevelParity() throws {
        let configuration = Configuration(
            version: 1,
            project: ProjectSettings(),
            sources: SourceSettings(),
            tests: TestSettings(),
            operators: OperatorSettings(),
            execution: ExecutionSettings(),
            timeouts: TimeoutSettings(),
            reports: [.console]
        )
        #expect(try encodedKeys(configuration) == topLevelKeys(in: try schema))
    }

    @Test("project/sources/tests/operators sections each match their struct")
    func leafSections() throws {
        let schema = try schema
        let project = ProjectSettings(kind: .auto, path: "p", scheme: "s", destination: "d", derivedDataPath: "dd")
        #expect(try encodedKeys(project) == section("project", in: schema))

        let sources = SourceSettings(include: ["a"], exclude: ["b"])
        #expect(try encodedKeys(sources) == section("sources", in: schema))

        let tests = TestSettings(targets: ["t"], extraArguments: ["--x"], parallel: true)
        #expect(try encodedKeys(tests) == section("tests", in: schema))

        let operators = OperatorSettings(profile: .default, disable: ["x"], enable: ["y"])
        #expect(try encodedKeys(operators) == section("operators", in: schema))
    }

    @Test("execution, including its nested budget, matches ExecutionSettings")
    func executionSection() throws {
        let schema = try schema
        let execution = ExecutionSettings(
            strategy: .schemata, workers: 4,
            budget: BudgetSettings(
                maxMutants: 10, maxDurationSeconds: 60, seed: 1, stratifyBy: .operatorSubtype,
                minimumPerOperator: 5, selection: .v2, minimumPerStratum: 2, weight: ["opA": 1]
            ),
            diffBase: "origin/main", measureCoverage: true, retestKilledMutants: true,
            confirmCrashKills: true, confirmTimedOutMutants: true, selectCoveringTests: true,
            incrementalBuild: true, earlyAbortSelectedTests: true, testBatchSize: 8
        )
        #expect(try encodedKeys(execution) == section("execution", in: schema))

        // Budget is its own Codable struct nested under execution.
        let budget = BudgetSettings(
            maxMutants: 10, maxDurationSeconds: 60, seed: 1, stratifyBy: .operatorSubtype,
            minimumPerOperator: 5, selection: .v2, minimumPerStratum: 2, weight: ["opA": 1]
        )
        #expect(try encodedKeys(budget) == nestedSection(["execution", "budget"], in: schema))
    }

    @Test("timeouts, including its nested mutant, matches TimeoutSettings")
    func timeoutsSection() throws {
        let schema = try schema
        let timeouts = TimeoutSettings(
            baselineSeconds: 120,
            mutant: MutantTimeoutSettings(
                strategy: .adaptive, multiplier: 3, minimumSeconds: 30,
                maximumSeconds: 300, overheadAllowanceSeconds: 60
            ),
            terminationGracePeriodSeconds: 5
        )
        #expect(try encodedKeys(timeouts) == section("timeouts", in: schema))

        let mutant = MutantTimeoutSettings(
            strategy: .fixed, multiplier: 2, minimumSeconds: 10,
            maximumSeconds: 100, overheadAllowanceSeconds: 5
        )
        #expect(try encodedKeys(mutant) == nestedSection(["timeouts", "mutant"], in: schema))
    }

    /// `ConfigurationJSONSchema.document`'s `$id` claims a real,
    /// `raw.githubusercontent.com` URL (see that type's doc comment) that
    /// resolves to `Schema/mutantkit-v1.json` in this very repository. That
    /// only stays true if the checked-in file and the embedded document
    /// never drift apart — this compares them as parsed JSON (not raw text)
    /// so formatting differences don't count as drift, only actual content
    /// differences do.
    @Test("The checked-in Schema/mutantkit-v1.json matches the embedded schema exactly")
    func checkedInSchemaFileMatchesEmbeddedDocument() throws {
        let schemaFileURL = Acceptance.packageRoot.appendingPathComponent("Schema/mutantkit-v1.json")
        let fileData = try Data(contentsOf: schemaFileURL)
        let embeddedData = Data(ConfigurationJSONSchema.document.utf8)

        let fileObject = try JSONSerialization.jsonObject(with: fileData)
        let embeddedObject = try JSONSerialization.jsonObject(with: embeddedData)

        // Re-serialize both with sorted keys so key order (irrelevant to a
        // JSON Schema's meaning) can't mask or manufacture a mismatch.
        let fileCanonical = try JSONSerialization.data(withJSONObject: fileObject, options: [.sortedKeys])
        let embeddedCanonical = try JSONSerialization.data(withJSONObject: embeddedObject, options: [.sortedKeys])

        #expect(fileCanonical == embeddedCanonical)
    }

    @Test("qualityGate matches QualityGateSettings")
    func qualityGateSection() throws {
        let schema = try schema
        let settings = QualityGateSettings(
            testedScore: .init(minimum: 80),
            effectiveScore: .init(minimum: 70),
            regression: .init(maximumDrop: 2),
            survived: .init(newMaximum: 0),
            integrityViolations: .init(maximum: 0)
        )
        #expect(try encodedKeys(settings) == section("qualityGate", in: schema))
    }

    // MARK: - Helpers

    /// Keys a fully-populated value encodes to. Sorted to make equality reads
    /// deterministic; the comparison is set-based either way.
    private func encodedKeys(_ value: some Encodable) throws -> Set<String> {
        let object = try #require(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value)) as? [String: Any]
        )
        return Set(object.keys)
    }

    private func section(_ name: String, in schema: [String: Any]) throws -> Set<String> {
        let properties = try #require(schema["properties"] as? [String: Any])
        let sectionObject = try #require(properties[name] as? [String: Any])
        let sectionProperties = try #require(sectionObject["properties"] as? [String: Any])
        return Set(sectionProperties.keys)
    }

    private func topLevelKeys(in schema: [String: Any]) throws -> Set<String> {
        let properties = try #require(schema["properties"] as? [String: Any])
        return Set(properties.keys)
    }

    private func nestedSection(_ path: [String], in schema: [String: Any]) throws -> Set<String> {
        let properties = try #require(schema["properties"] as? [String: Any])
        var current: [String: Any] = properties
        for (index, key) in path.enumerated() {
            let object = try #require(current[key] as? [String: Any])
            if index == path.count - 1 {
                let nested = try #require(object["properties"] as? [String: Any])
                return Set(nested.keys)
            }
            current = try #require(object["properties"] as? [String: Any])
        }
        return []
    }
}
