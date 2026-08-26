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
        family: String = "boolean-literal", bucket: NormalizedMutant.Bucket = .killed, provenActive: Bool? = nil,
        line: Int = 0, column: Int = 0
    ) -> NormalizedMutant {
        NormalizedMutant(
            identity: CrossToolMutationIdentity(
                relativePath: path, startUTF8Offset: start, endUTF8Offset: end,
                originalTextHash: ResultNormalizer.sha256Hex(original), replacementTextHash: ResultNormalizer.sha256Hex(replacement),
                normalizedOperatorFamily: family, line: line, column: column
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

    /// Regression test for the real "0 matched mutants" calibration
    /// finding (Phase C13). A real Muter report never carries mutation
    /// text at all (`CrossToolMutationIdentity`'s own doc comment has the
    /// full account), so a real Muter mutant's `originalTextHash`/
    /// `replacementTextHash` always hash an empty string — deliberately
    /// reproduced here (`original: "", replacement: ""`) rather than
    /// reusing the same non-empty text `makeMutant`'s defaults would give
    /// both sides, since the whole point is proving the match survives
    /// *despite* that empty-vs-real-text mismatch, using only line/column.
    @Test("Cross-tool matching succeeds via line/column even though Muter's real text hashes are always empty")
    func matchesViaLineColumnDespiteMuterEmptyTextHashes() {
        let mk = makeMutant(original: "<", replacement: ">=", line: 29, column: 18)
        let muter = makeMutant(original: "", replacement: "", line: 29, column: 18)
        let comparison = ResultNormalizer.match(mutantKit: [mk], muter: [muter])
        #expect(comparison.exactlyComparable.count == 1, "must match on (path, line, column) alone, not text hashes")
        #expect(comparison.mutantKitOnly.isEmpty)
        #expect(comparison.muterOnly.isEmpty)
    }

    /// A file with more than one real mutation at the exact same
    /// (line, column) — MutantKit trying several replacements of the same
    /// token where Muter tries exactly one — is a real, accepted
    /// consequence of dropping text-hash matching (see
    /// `CrossToolMutationIdentity`'s doc comment): both MutantKit mutants
    /// correctly match the one real Muter mutant at that position, never
    /// silently dropped.
    @Test("Multiple MutantKit mutants at the same position each match the one real Muter mutant there")
    func multipleMutantKitMutantsAtSamePositionAllMatch() {
        let mkLessEqual = makeMutant(replacement: "<=", line: 29, column: 18)
        let mkGreaterEqual = makeMutant(replacement: ">=", line: 29, column: 18)
        let muter = makeMutant(original: "", replacement: "", line: 29, column: 18)
        let comparison = ResultNormalizer.match(mutantKit: [mkLessEqual, mkGreaterEqual], muter: [muter])
        #expect(comparison.exactlyComparable.count == 2)
        #expect(comparison.muterOnly.isEmpty)
    }

    // MARK: - Muter relative-path resolution (Phase C13)

    /// Regression test for a second, compounding reason the real
    /// calibration run found zero matches: Muter's own file-report groups
    /// by bare basename (`"GCD.swift"`, confirmed against a real report),
    /// which can never equal MutantKit's real relative path
    /// (`"Sources/IntegerUtilities/GCD.swift"`) as strings, independently
    /// of the text-hash issue.
    @Test("relativePath resolves the real project-relative path by probing the filesystem")
    func relativePathResolvesRealNestedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rn-relpath-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/IntegerUtilities")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("GCD.swift"))
        defer { try? FileManager.default.removeItem(at: root) }

        let muterAbsolutePath = "/private/var/folders/x/y/T/mutantbench-example_mutated/Sources/IntegerUtilities/GCD.swift"
        let resolved = ResultNormalizer.relativePath(forMuterFilePath: muterAbsolutePath, fallback: "GCD.swift", projectDirectory: root)
        #expect(resolved == "Sources/IntegerUtilities/GCD.swift")
    }

    @Test("relativePath falls back to the bare basename when nothing resolves on disk")
    func relativePathFallsBackWhenNoFileExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rn-relpath-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = ResultNormalizer.relativePath(
            forMuterFilePath: "/tmp/somewhere_mutated/Sources/Nowhere.swift", fallback: "Nowhere.swift", projectDirectory: root
        )
        #expect(resolved == "Nowhere.swift")
    }

    @Test("relativePath falls back to the bare basename when projectDirectory is nil")
    func relativePathFallsBackWhenNoProjectDirectory() {
        let resolved = ResultNormalizer.relativePath(forMuterFilePath: "/tmp/x_mutated/Sources/A.swift", fallback: "A.swift", projectDirectory: nil)
        #expect(resolved == "A.swift")
    }

    /// End-to-end proof against the real captured calibration report data
    /// (`Benchmarks/results/.../stage1-calibration/raw/`) that motivated
    /// this whole fix — a minimal stub tree (empty files, only the real
    /// paths matter for resolution) stands in for the real swift-numerics
    /// checkout so this stays a fast, offline unit test.
    @Test("normalizeMuterReport resolves a real relative path from a real per-mutation filePath")
    func normalizeMuterReportResolvesRealRelativePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rn-real-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/IntegerUtilities")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("GCD.swift"))
        defer { try? FileManager.default.removeItem(at: root) }

        // Trimmed from the real captured
        // swift-numerics-muter-cold-0.json this bug was found against.
        let data = Data(#"""
        {
          "fileReports": [{
            "fileName": "GCD.swift",
            "appliedOperators": [{
              "testSuiteOutcome": "passed",
              "mutationPoint": {
                "filePath": "/private/var/folders/g3/x/T/mutantbench-swift-numerics-muter-cold-0_mutated/Sources/IntegerUtilities/GCD.swift",
                "position": {"line": 29, "column": 18, "utf8Offset": 1198},
                "mutationOperatorId": "RelationalOperatorReplacement"
              }
            }]
          }]
        }
        """#.utf8)
        let mutants = try ResultNormalizer.normalizeMuterReport(data, projectDirectory: root)
        #expect(mutants.count == 1)
        #expect(mutants[0].identity.relativePath == "Sources/IntegerUtilities/GCD.swift")
        #expect(mutants[0].identity.line == 29)
        #expect(mutants[0].identity.column == 18)
        #expect(mutants[0].identity.startUTF8Offset == 1198, "the real utf8Offset field must be parsed, not the old synthetic packing")
    }

    /// End-to-end proof against the exact real calibration pair that
    /// originally motivated this whole fix (Phase C13) — not a
    /// hand-crafted approximation of it. Before this fix,
    /// `ResultNormalizer.match` found **zero** matched mutants for this
    /// real corpus/file/operator combination; this asserts the real,
    /// corrected count directly, so a future regression here fails loudly
    /// rather than silently reverting to the original bug.
    @Test("The real swift-numerics calibration pair now matches, where it previously matched zero")
    func realCalibrationPairNowMatches() throws {
        // Walks up from this test file's own location to find the repo
        // root — resilient to `swift test`'s own working directory, which
        // varies by invocation (same pattern as `BenchmarkManifestTests
        // .realManifestDecodes`).
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Benchmarks/manifest.json").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else {
                Issue.record("could not locate the repo root above \(#filePath)")
                return
            }
            directory = parent
        }
        let base = directory.appendingPathComponent(
            "Benchmarks/results/compatibility/xcode-15.2-swift-5.9-macos-14/stage1-calibration/raw"
        )
        let mkData = try Data(contentsOf: base.appendingPathComponent("swift-numerics-mutantkit-cold-0.json"))
        let muterData = try Data(contentsOf: base.appendingPathComponent("swift-numerics-muter-cold-0.json"))
        // A minimal stub stands in for the real swift-numerics checkout:
        // `relativePath` resolution only needs the real file to *exist*
        // on disk at the right relative path, never its content, so this
        // stays a fast, offline, no-network test.
        let stub = FileManager.default.temporaryDirectory.appendingPathComponent("swift-numerics-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stub.appendingPathComponent("Sources/IntegerUtilities"), withIntermediateDirectories: true)
        try Data().write(to: stub.appendingPathComponent("Sources/IntegerUtilities/GCD.swift"))
        defer { try? FileManager.default.removeItem(at: stub) }

        let mk = try ResultNormalizer.normalizeMutantKitReport(mkData).mutants
        let muter = try ResultNormalizer.normalizeMuterReport(muterData, projectDirectory: stub)
        let comparison = ResultNormalizer.match(mutantKit: mk, muter: muter)

        // 4 MutantKit mutants at 3 real Muter mutation sites in GCD.swift
        // (one site, line 29 col 18, has 2 MutantKit replacements against
        // Muter's 1 — both correctly match that one real Muter mutant,
        // per this type's own documented, accepted N:1 correspondence).
        #expect(comparison.exactlyComparable.count == 4)
        #expect(comparison.mutantKitOnly.isEmpty)
        #expect(comparison.muterOnly.isEmpty)
    }

    // MARK: - swift-mutation-testing report.json (Phase C13)

    /// Real shape confirmed against `ericodx/swift-mutation-testing`'s own
    /// `Docs/STRYKER-COMPATIBILITY.md` — a top-level `files` dictionary
    /// keyed by a path already relative to `projectRoot`, each holding a
    /// `mutants` array with real `originalText`/`replacement`/`location`/
    /// `status` fields (unlike Muter's report, which never carries the
    /// mutated text at all).
    @Test("A real swift-mutation-testing report shape parses real mutants with real relative paths")
    func realSwiftMutationTestingReportShapeParses() throws {
        let data = Data(#"""
        {
          "schemaVersion": "1",
          "thresholds": {"high": 80, "low": 60},
          "projectRoot": "/tmp/example",
          "files": {
            "/Sources/IntegerUtilities/GCD.swift": {
              "language": "swift",
              "source": "...",
              "mutants": [
                {
                  "id": "swift-mutation-testing_1",
                  "mutatorName": "RelationalOperatorReplacement",
                  "originalText": "<",
                  "replacement": ">=",
                  "location": {"start": {"line": 29, "column": 18}, "end": {"line": 29, "column": 19}},
                  "status": "Survived",
                  "killedBy": null,
                  "description": "< → >="
                },
                {
                  "id": "swift-mutation-testing_2",
                  "mutatorName": "BooleanLiteralReplacement",
                  "originalText": "true",
                  "replacement": "false",
                  "location": {"start": {"line": 12, "column": 5}, "end": {"line": 12, "column": 9}},
                  "status": "Killed",
                  "killedBy": "testFoo",
                  "description": "true → false"
                }
              ]
            }
          }
        }
        """#.utf8)
        let mutants = try ResultNormalizer.normalizeSwiftMutationTestingReport(data)
        #expect(mutants.count == 2)
        // The real `JsonReporter` key is `/Sources/IntegerUtilities/GCD.swift`
        // (a leading-slash-retaining `dropFirst(projectRoot.count)`, real
        // bug found by Codex review before this was committed as done) —
        // this asserts the leading slash was actually stripped, matching
        // MutantKit's own leading-slash-free `relativePath` convention.
        #expect(mutants.allSatisfy { $0.identity.relativePath == "Sources/IntegerUtilities/GCD.swift" })
        #expect(mutants.filter { $0.bucket == .survived }.count == 1)
        #expect(mutants.filter { $0.bucket == .killed }.count == 1)
        let survivor = try #require(mutants.first { $0.bucket == .survived })
        #expect(survivor.identity.line == 29)
        #expect(survivor.identity.column == 18)
        #expect(survivor.identity.normalizedOperatorFamily == "relational-operator")
    }

    @Test("A Crash status counts as killed, per the tool's own documented rationale")
    func swiftMutationTestingCrashCountsAsKilled() throws {
        let data = Data(#"""
        {"files": {"/A.swift": {"mutants": [{
          "mutatorName": "RemoveSideEffects", "location": {"start": {"line": 1, "column": 1}}, "status": "Crash"
        }]}}}
        """#.utf8)
        let mutants = try ResultNormalizer.normalizeSwiftMutationTestingReport(data)
        #expect(mutants.count == 1)
        #expect(mutants[0].bucket == .killed)
        #expect(mutants[0].identity.normalizedOperatorFamily == "remove-side-effects")
        #expect(mutants[0].identity.relativePath == "A.swift")
    }

    @Test("A mutant entry missing a required field is skipped, not fabricated")
    func malformedSwiftMutationTestingEntryIsSkipped() throws {
        let data = Data(#"""
        {"files": {"/A.swift": {"mutants": [
          {"mutatorName": "RelationalOperatorReplacement"},
          {"mutatorName": "BooleanLiteralReplacement", "location": {"start": {"line": 4, "column": 2}}, "status": "Killed"}
        ]}}}
        """#.utf8)
        let mutants = try ResultNormalizer.normalizeSwiftMutationTestingReport(data)
        #expect(mutants.count == 1, "the entry missing location/status must be dropped, not defaulted")
    }

    @Test("A files key without a leading slash (defensive) is left as-is, not double-processed")
    func relativePathWithoutLeadingSlashIsUnaffected() throws {
        let data = Data(#"""
        {"files": {"Sources/A.swift": {"mutants": [{
          "mutatorName": "BooleanLiteralReplacement", "location": {"start": {"line": 1, "column": 1}}, "status": "Killed"
        }]}}}
        """#.utf8)
        let mutants = try ResultNormalizer.normalizeSwiftMutationTestingReport(data)
        #expect(mutants.count == 1)
        #expect(mutants[0].identity.relativePath == "Sources/A.swift")
    }

    /// Real, end-to-end proof the same line/column match key that fixed
    /// MutantKit's benchmark normalization mismatch when consuming Muter
    /// results (the old text-hash match key assumed every tool's report
    /// carries the mutated text; Muter's own report format never does —
    /// see `CrossToolMutationIdentity`'s own doc comment for the full,
    /// correctly-attributed account) also correctly matches MutantKit
    /// against swift-mutation-testing, whose report — unlike Muter's —
    /// already carries real text; this proves the match still works when
    /// keyed on line/column rather than those (real, non-empty) hashes.
    @Test("MutantKit and swift-mutation-testing mutants at the same real position match")
    func matchesAgainstSwiftMutationTesting() throws {
        let mkData = Data(#"""
        {"results": [{
          "point": {
            "file": "Sources/IntegerUtilities/GCD.swift", "utf8Range": {"start": 1126, "end": 1127},
            "originalText": "<", "replacementText": ">=", "operatorID": "swift.core.relational-operator-replacement",
            "line": 29, "column": 18
          },
          "outcome": "survived"
        }]}
        """#.utf8)
        // Real key shape: `JsonReporter`'s `dropFirst(projectRoot.count)`
        // retains a leading `/` (confirmed against its real source) —
        // used here, not the leading-slash-free shape, so this end-to-end
        // test exercises the actual strip this fix performs.
        let smtData = Data(#"""
        {"files": {"/Sources/IntegerUtilities/GCD.swift": {"mutants": [{
          "mutatorName": "RelationalOperatorReplacement", "originalText": "<", "replacement": ">=",
          "location": {"start": {"line": 29, "column": 18}}, "status": "Survived"
        }]}}}
        """#.utf8)
        let mk = try ResultNormalizer.normalizeMutantKitReport(mkData).mutants
        let smt = try ResultNormalizer.normalizeSwiftMutationTestingReport(smtData)
        let comparison = ResultNormalizer.match(mutantKit: mk, comparedAgainst: smt)
        #expect(comparison.exactlyComparable.count == 1)
        #expect(comparison.mutantKitOnly.isEmpty)
        #expect(comparison.muterOnly.isEmpty)
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
