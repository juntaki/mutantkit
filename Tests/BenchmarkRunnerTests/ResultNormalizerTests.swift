@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("ResultNormalizer")
struct ResultNormalizerTests {
    // MARK: - Malformed / partial reports

    @Test("Malformed JSON (not even an object) throws, never returns an empty-but-successful result")
    func malformedJSONThrows() throws {
        #expect(throws: Error.self) {
            _ = try ResultNormalizer.normalizeMutantKitReport(Data("not json at all".utf8))
        }
        #expect(throws: Error.self) {
            _ = try ResultNormalizer.normalizeMuterReport(Data("[1, 2, 3]".utf8))
        }
    }

    @Test("A real Muter report (no mutationSnapshot field, confirmed against Muter's own CodingKeys) still parses real mutants")
    func realMuterReportShapeWithoutSnapshotStillParses() throws {
        // Captured from a real `muter run --format json` output — Muter's
        // own `AppliedMutationOperator.CodingKeys` (Sources/muterCore/
        // TestReporting/MuterTestReport.swift) explicitly omits
        // `mutationSnapshot` from encoding, at any version. A prior version
        // of this parser required that field and silently dropped every
        // real mutant as a result.
        let data = Data(#"""
        {
          "globalMutationScore": 66,
          "numberOfKilledMutants": 2,
          "fileReports": [
            {
              "mutationScore": 66,
              "appliedOperators": [
                {
                  "testSuiteOutcome": "passed",
                  "mutationPoint": {
                    "position": {"line": 29, "column": 18},
                    "filePath": "/tmp/x_mutated/Sources/IntegerUtilities/GCD.swift",
                    "mutationOperatorId": "RelationalOperatorReplacement"
                  }
                },
                {
                  "testSuiteOutcome": "failed",
                  "mutationPoint": {
                    "position": {"line": 31, "column": 18},
                    "filePath": "/tmp/x_mutated/Sources/IntegerUtilities/GCD.swift",
                    "mutationOperatorId": "RelationalOperatorReplacement"
                  }
                },
                {
                  "testSuiteOutcome": "runtimeError",
                  "mutationPoint": {
                    "position": {"line": 35, "column": 11},
                    "filePath": "/tmp/x_mutated/Sources/IntegerUtilities/GCD.swift",
                    "mutationOperatorId": "RelationalOperatorReplacement"
                  }
                }
              ],
              "fileName": "GCD.swift"
            }
          ],
          "timeElapsed": "00:01:24.088",
          "totalAppliedMutationOperators": 3
        }
        """#.utf8)
        let mutants = try ResultNormalizer.normalizeMuterReport(data)
        #expect(mutants.count == 3, "all 3 real mutations must be counted, not dropped for missing mutationSnapshot")
        #expect(mutants.filter { $0.bucket == .killed }.count == 2, "failed + runtimeError both count as killed")
        #expect(mutants.filter { $0.bucket == .survived }.count == 1, "passed counts as survived")
    }

    @Test("A partial MutantKit report (missing 'results') parses as zero mutants, not an error")
    func partialMutantKitReportParsesAsEmpty() throws {
        let data = Data(#"{"integrity": {"passed": true}}"#.utf8)
        let parsed = try ResultNormalizer.normalizeMutantKitReport(data)
        #expect(parsed.mutants.isEmpty)
        #expect(parsed.integrityPassed)
    }

    @Test("A MutantKit result entry missing a required field is skipped, not fabricated")
    func malformedResultEntryIsSkipped() throws {
        let data = Data(#"""
        {
          "results": [
            {"point": {"file": "A.swift"}},
            {"point": {"file": "B.swift", "utf8Range": {"start": 0, "end": 4}, "originalText": "true", "replacementText": "false", "operatorID": "swift.core.bool-literal-inversion"}, "outcome": "killedByAssertion"}
          ]
        }
        """#.utf8)
        let parsed = try ResultNormalizer.normalizeMutantKitReport(data)
        #expect(parsed.mutants.count == 1, "the entry missing utf8Range/outcome must be dropped, not defaulted")
        #expect(parsed.mutants[0].identity.relativePath == "B.swift")
    }

    @Test("A phantomMutant integrity violation is reflected in phantomMutants, read from the real report field")
    func phantomMutantsAreCountedFromRealViolations() throws {
        let data = Data(#"""
        {
          "results": [],
          "integrity": {
            "passed": false,
            "planned": 4,
            "violations": [
              {"kind": "phantomMutant", "detail": "..."},
              {"kind": "baselineMismatch", "detail": "..."}
            ]
          }
        }
        """#.utf8)
        let parsed = try ResultNormalizer.normalizeMutantKitReport(data)
        #expect(parsed.phantomMutants == 1, "only the phantomMutant violation counts, not baselineMismatch")
        #expect(parsed.plannedMutations == 4)
    }

    @Test("integrityPassed is derived from violations.isEmpty, never a 'passed' JSON key MutantKit never actually writes")
    func integrityPassedIsDerivedFromViolationsNotAMissingKey() throws {
        // Real shape: `IntegrityReport.passed` (Sources/MutationModel/
        // Integrity.swift) is a computed property, `violations.isEmpty` —
        // it has no backing storage and is never serialized. A prior
        // version of this parser looked for a "passed" key that can never
        // exist, silently marking every real MutantKit run correctness-
        // FAILED (confirmed against a real Stage 1 calibration run).
        let clean = Data(#"""
        {"results": [], "integrity": {"planned": 4, "discovered": 4, "violations": []}}
        """#.utf8)
        #expect(try ResultNormalizer.normalizeMutantKitReport(clean).integrityPassed)

        let violated = Data(#"""
        {"results": [], "integrity": {"planned": 4, "violations": [{"kind": "phantomMutant", "detail": "..."}]}}
        """#.utf8)
        #expect(!(try ResultNormalizer.normalizeMutantKitReport(violated).integrityPassed))
    }

    @Test("A scorable result with verificationVersion 0 is counted as false-scored")
    func falseScoredCountsUnverifiedRecords() throws {
        let data = Data(#"""
        {
          "results": [
            {
              "point": {"file": "A.swift", "utf8Range": {"start": 0, "end": 4}, "originalText": "true", "replacementText": "false", "operatorID": "swift.core.bool-literal-inversion"},
              "outcome": "killedByAssertion",
              "verificationVersion": 0
            },
            {
              "point": {"file": "B.swift", "utf8Range": {"start": 0, "end": 4}, "originalText": "true", "replacementText": "false", "operatorID": "swift.core.bool-literal-inversion"},
              "outcome": "killedByAssertion",
              "verificationVersion": 1
            }
          ]
        }
        """#.utf8)
        let parsed = try ResultNormalizer.normalizeMutantKitReport(data)
        #expect(parsed.falseScoredMutants == 1, "only the verificationVersion:0 record is false-scored")
    }

    // MARK: - Backend disagreement

    @Test("Two reports of the same mutation with different outcomes are counted as a disagreement")
    func compareBackendsFindsADisagreement() throws {
        func report(outcome: String) -> Data {
            Data(#"""
            {"results": [{
              "point": {"file": "A.swift", "utf8Range": {"start": 0, "end": 4}, "originalText": "true", "replacementText": "false", "operatorID": "swift.core.bool-literal-inversion"},
              "outcome": "\#(outcome)"
            }]}
            """#.utf8)
        }
        let comparison = try ResultNormalizer.compareBackends(
            isolatedReportData: report(outcome: "killedByAssertion"), schemataReportData: report(outcome: "survived")
        )
        #expect(comparison.comparableMutations == 1)
        #expect(comparison.disagreements == 1)
        #expect(comparison.details.first?.isolatedOutcome == "killed")
        #expect(comparison.details.first?.schemataOutcome == "survived")
    }

    @Test("Identical outcomes across both reports are not a disagreement")
    func compareBackendsFindsNoDisagreementWhenOutcomesMatch() throws {
        let data = Data(#"""
        {"results": [{
          "point": {"file": "A.swift", "utf8Range": {"start": 0, "end": 4}, "originalText": "true", "replacementText": "false", "operatorID": "swift.core.bool-literal-inversion"},
          "outcome": "killedByAssertion"
        }]}
        """#.utf8)
        let comparison = try ResultNormalizer.compareBackends(isolatedReportData: data, schemataReportData: data)
        #expect(comparison.comparableMutations == 1)
        #expect(comparison.disagreements == 0)
    }

    @Test("A mutation only one report contains is not comparable, never silently treated as agreement")
    func compareBackendsExcludesToolOnlyMutations() throws {
        let isolatedOnly = Data(#"""
        {"results": [{
          "point": {"file": "OnlyIsolated.swift", "utf8Range": {"start": 0, "end": 4}, "originalText": "true", "replacementText": "false", "operatorID": "swift.core.bool-literal-inversion"},
          "outcome": "killedByAssertion"
        }]}
        """#.utf8)
        let empty = Data(#"{"results": []}"#.utf8)
        let comparison = try ResultNormalizer.compareBackends(isolatedReportData: isolatedOnly, schemataReportData: empty)
        #expect(comparison.comparableMutations == 0)
        #expect(comparison.disagreements == 0)
    }

    // MARK: - Unknown metrics remain nil

    @Test("A crashed run with no report data yields a measurement with every count-from-report field nil")
    func unmeasurableFieldsStayNil() {
        let measurement = MutationBenchmarkMeasurement(
            runID: UUID(), tool: BenchmarkToolIdentity(name: "mutantkit", version: "0"), projectID: "p", projectCommit: "c",
            mode: .cold, toolchainProfileID: "test", discovered: 0, applied: nil, built: nil, provenActive: nil, provenExecuted: nil,
            killed: 0, survived: 0, noCoverage: 0, unviable: 0, infrastructureFailure: 0,
            phantom: nil, falseScored: nil, backendDisagreements: nil,
            wallSeconds: 1.0, peakResidentBytes: nil, workingDirectoryGrowthBytes: nil, exitCode: 1
        )
        #expect(measurement.applied == nil)
        #expect(measurement.provenActive == nil)
        #expect(measurement.peakResidentBytes == nil)
    }

    // MARK: - Cross-tool matching

    private func makeMutant(
        path: String = "Widget.swift", start: Int = 10, end: Int = 14, original: String = "true", replacement: String = "false",
        family: String = "boolean-literal", bucket: NormalizedMutant.Bucket = .killed, provenActive: Bool? = nil
    ) -> NormalizedMutant {
        NormalizedMutant(
            identity: CrossToolMutationIdentity(
                relativePath: path, startUTF8Offset: start, endUTF8Offset: end,
                originalTextHash: ResultNormalizer.sha256Hex(original), replacementTextHash: ResultNormalizer.sha256Hex(replacement),
                normalizedOperatorFamily: family
            ),
            bucket: bucket, provenActive: provenActive
        )
    }

    @Test("The same edit, same operator family, matches exactly")
    func exactMatch() {
        let mk = makeMutant(provenActive: true)
        let muter = makeMutant()
        let comparison = ResultNormalizer.match(mutantKit: [mk], muter: [muter])
        #expect(comparison.exactlyComparable.count == 1)
        #expect(comparison.approximatelyComparable.isEmpty)
        #expect(comparison.mutantKitOnly.isEmpty)
        #expect(comparison.muterOnly.isEmpty)
    }

    @Test("The same edit but a different operator family matches only approximately")
    func approximateMatch() {
        let mk = makeMutant(family: "boolean-literal")
        let muter = makeMutant(family: "relational-operator")
        let comparison = ResultNormalizer.match(mutantKit: [mk], muter: [muter])
        #expect(comparison.exactlyComparable.isEmpty)
        #expect(comparison.approximatelyComparable.count == 1)
    }

    @Test("A mutant only one tool reports lands in that tool's own -only bucket")
    func toolOnlyMutantsAreBucketedSeparately() {
        let mkOnly = makeMutant(path: "OnlyMK.swift")
        let muterOnly = makeMutant(path: "OnlyMuter.swift")
        let comparison = ResultNormalizer.match(mutantKit: [mkOnly], muter: [muterOnly])
        #expect(comparison.exactlyComparable.isEmpty)
        #expect(comparison.mutantKitOnly.map(\.identity.relativePath) == ["OnlyMK.swift"])
        #expect(comparison.muterOnly.map(\.identity.relativePath) == ["OnlyMuter.swift"])
    }

    // MARK: - Median

    @Test("Median of an odd count is the middle value")
    func medianOddCount() {
        #expect(ResultNormalizer.median([3, 1, 2]) == 2)
    }

    @Test("Median of an even count averages the two middle values")
    func medianEvenCount() {
        #expect(ResultNormalizer.median([1, 2, 3, 4]) == 2.5)
    }

    @Test("Median is not skewed the way a mean would be by one outlier run")
    func medianResistsOutliers() {
        let values: [Double] = [10, 11, 9, 500]
        #expect(ResultNormalizer.median(values) == 10.5)
        let mean = values.reduce(0, +) / Double(values.count)
        #expect(mean > 100, "the mean is dominated by the outlier — confirms median is the meaningfully different choice")
    }

    @Test("Median of an empty array is nil, never 0")
    func medianOfEmptyIsNil() {
        #expect(ResultNormalizer.median([]) == nil)
    }
}
