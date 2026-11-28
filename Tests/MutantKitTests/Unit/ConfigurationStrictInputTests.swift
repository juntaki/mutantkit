@testable import CLI
import Foundation
import MutationModel
import Testing

/// Explicit configuration input must not be silently replaced by a default:
/// absent/null, the intentional `auto`, and an invalid value are three
/// different things.
@Suite("Configuration: explicit values are decoded strictly")
struct ConfigurationStrictInputTests {
    private func parse(_ body: String) throws -> Configuration {
        try ConfigurationLoader.parse("version: 1\n" + body, environment: [:])
    }

    @Test("workers: absent, null and auto all mean automatic; an integer is kept")
    func workersAutoForms() throws {
        #expect(try parse("").execution.workers == nil)
        #expect(try parse("execution:\n  workers: null\n").execution.workers == nil)
        #expect(try parse("execution:\n  workers: auto\n").execution.workers == nil)
        #expect(try parse("execution:\n  workers: 3\n").execution.workers == 3)
    }

    @Test("workers: any other string is rejected instead of becoming auto")
    func workersInvalidString() {
        #expect(throws: ConfigurationError.self) { try parse("execution:\n  workers: abc\n") }
        #expect(throws: ConfigurationError.self) { try parse("execution:\n  workers: Auto\n") }
    }

    @Test("timeouts: malformed durations are rejected instead of becoming the default")
    func malformedDuration() throws {
        #expect(try parse("timeouts:\n  mutant:\n    minimum: 90s\n").timeouts.mutant.minimumSeconds == 90)
        #expect(try parse("timeouts:\n  mutant:\n    maximum: 1h30m\n").timeouts.mutant.maximumSeconds == 5400)
        #expect(try parse("timeouts:\n  mutant:\n    overheadAllowance: 5\n").timeouts.mutant.overheadAllowanceSeconds == 5)
        for key in ["minimum", "maximum", "overheadAllowance"] {
            #expect(throws: ConfigurationError.self, "\(key): 10x") { try parse("timeouts:\n  mutant:\n    \(key): 10x\n") }
            #expect(throws: ConfigurationError.self, "\(key): soon") { try parse("timeouts:\n  mutant:\n    \(key): soon\n") }
        }
    }

    @Test("timeouts: nonfinite durations are rejected")
    func nonfiniteDuration() {
        for literal in [".nan", ".inf", "-.inf", "\"inf\"", "\"nan\""] {
            #expect(throws: ConfigurationError.self, "maximum: \(literal)") {
                try parse("timeouts:\n  mutant:\n    maximum: \(literal)\n")
            }
        }
        #expect(DurationParser.seconds(from: "inf") == nil)
        #expect(DurationParser.seconds(from: "nan") == nil)
    }

    // MARK: - Unknown and duplicate keys

    private func message(_ body: String) -> String {
        do {
            _ = try parse(body)
            return ""
        } catch {
            return "\(error)"
        }
    }

    @Test("A misspelled top-level or nested key is rejected, naming the key and where it is")
    func unknownKeys() {
        let top = message("exectuion:\n  workers: 2\n")
        #expect(top.contains("unknown key 'exectuion'"), "\(top)")
        let nested = message("execution:\n  workerz: 2\n")
        #expect(nested.contains("unknown key 'workerz'") && nested.contains("execution"), "\(nested)")
        let deep = message("timeouts:\n  mutant:\n    minimun: 5\n")
        #expect(deep.contains("unknown key 'minimun'") && deep.contains("timeouts.mutant"), "\(deep)")
        let budget = message("execution:\n  budget:\n    maxMutant: 5\n")
        #expect(budget.contains("unknown key 'maxMutant'"), "\(budget)")
        let gate = message("qualityGate:\n  testedScore:\n    minimun: 5\n")
        #expect(gate.contains("unknown key 'minimun'"), "\(gate)")
    }

    @Test("Unknown keys and duplicate keys are distinct errors")
    func distinctErrors() {
        do {
            _ = try parse("execution:\n  workerz: 2\n")
            Issue.record("unknown key accepted")
        } catch ConfigurationError.unknownKey {
        } catch {
            Issue.record("expected unknownKey, got \(error)")
        }
        do {
            _ = try parse("execution:\n  workers: 2\n  workers: 3\n")
            Issue.record("duplicate key accepted")
        } catch let ConfigurationError.malformed(_, underlying) {
            #expect(underlying.contains("workers"), "\(underlying)")
        } catch {
            Issue.record("expected malformed, got \(error)")
        }
    }

    @Test("A duplicate key is rejected at top level, nested, and inside an open map")
    func duplicateKeys() {
        #expect(throws: ConfigurationError.self) { try parse("project:\n  kind: auto\nproject:\n  kind: auto\n") }
        #expect(throws: ConfigurationError.self) {
            try parse("timeouts:\n  mutant:\n    maximum: 5\n    maximum: 6\n")
        }
        #expect(throws: ConfigurationError.self) {
            try parse("execution:\n  budget:\n    weight:\n      a: 1\n      a: 2\n")
        }
    }

    @Test("Open map keys (budget.weight) and explicit nulls are preserved")
    func intentionalKeysPreserved() throws {
        let configuration = try parse("""
        execution:
          budget:
            maxMutants: 10
            weight:
              swift.core.relational: 2
              other: 3
          workers: null
        operators:
          sideEffectCallRemoval:
            excludeCalls: [record]
        """)
        #expect(configuration.execution.budget.weight == ["swift.core.relational": 2, "other": 3])
        #expect(configuration.operators.sideEffectCallRemoval?.excludeCalls == ["record"])
    }

    @Test("A legacy budget key keeps its own diagnostic instead of a generic unknown-key one")
    func legacyBudgetKeyDiagnostic() {
        let text = message("execution:\n  budget:\n    sampling: balancedByOperator\n")
        #expect(text.contains("no longer exist"), "\(text)")
    }

    @Test("Every key a fully populated configuration encodes is accepted by the loader")
    func encodedConfigurationRoundTrips() throws {
        var configuration = Configuration()
        configuration.operators.sideEffectCallRemoval = SideEffectCallRemovalSettings(excludeCalls: ["x"])
        configuration.execution.coverageGranularity = .suite
        configuration.execution.coverageWorkers = 2
        configuration.execution.testBatchSize = 4
        configuration.evidence = EvidenceSettings(archive: true, keep: 2)
        configuration.qualityGate = QualityGateSettings(
            testedScore: .init(minimum: 1), effectiveScore: .init(minimum: 1),
            regression: .init(maximumDrop: 1), survived: .init(newMaximum: 1),
            integrityViolations: .init(maximum: 0)
        )
        let json = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        let parsed = try ConfigurationLoader.parse(json, environment: [:])
        #expect(parsed == configuration)
    }

    // MARK: - Schema / runtime agreement

    @Test("terminationGracePeriod accepts a number or a duration string, as the schema says")
    func terminationGracePeriodTypes() throws {
        #expect(try parse("timeouts:\n  terminationGracePeriod: 7\n").timeouts.terminationGracePeriodSeconds == 7)
        #expect(try parse("timeouts:\n  terminationGracePeriod: 30s\n").timeouts.terminationGracePeriodSeconds == 30)
        #expect(try parse("").timeouts.terminationGracePeriodSeconds == 5)
        #expect(throws: ConfigurationError.self) { try parse("timeouts:\n  terminationGracePeriod: soon\n") }
    }

    @Test("The schema admits workers: auto, which the runtime accepts")
    func schemaAdmitsWorkersAuto() throws {
        let data = Data(ConfigurationJSONSchema.document.utf8)
        let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let execution = try #require((schema["properties"] as? [String: Any])?["execution"] as? [String: Any])
        let workers = try #require((execution["properties"] as? [String: Any])?["workers"] as? [String: Any])
        #expect(String(describing: workers).contains("auto"))
    }

    @Test("YAML merge keys are expanded: merged keys are accepted when valid and rejected when unknown")
    func mergeKeys() throws {
        let valid = try parse("execution:\n  <<: &base {workers: 2}\n  strategy: isolated\n")
        #expect(valid.execution.workers == 2)
        #expect(message("execution:\n  <<: {workerz: 2}\n").contains("unknown key 'workerz'"))
    }
}
