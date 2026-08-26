@testable import AppleBuildAdapters
import Foundation
import Testing

/// Pins `XCResultAdapter.classify(batch:tree:configurationTestIdentifiers:)`
/// against real captured `xcresulttool` output from a batched `.xctestrun`
/// (three `TestConfigurations`: a clean pass, a plain assertion failure, and
/// a crash — built and run against a real fixture on Xcode 26.6), plus the
/// per-test hierarchy (`get test-results tests --compact`) that attribution
/// now reads instead of the flat, batch-wide `testFailures` array. A
/// hand-written fixture would only prove the parser handles the shape its
/// author imagined; this proves it handles the shape Xcode actually emits,
/// including the schema's real quirk of a crash's `failureText` being
/// prefixed `Crash:` with no other structural difference from a plain
/// assertion failure.
@Suite("XCResultAdapter: batch classification")
struct XCResultAdapterBatchTests {
    /// Captured verbatim, field order included, from a real batch bundle
    /// covering `mut_pass` (`CheckoutTests/testCouponRequiresTwentyMinimum`,
    /// passed), `mut_fail` (`AssertFailProbeTests/testFails`, a plain
    /// assertion failure) and `mut_crash`
    /// (`CrashProbeTests/testCrashes`, a fatalError).
    private static let capturedBatchSummary = Data("""
    {
        "devicesAndConfigurations": [
            {
                "expectedFailures": 0,
                "failedTests": 1,
                "passedTests": 0,
                "skippedTests": 0,
                "testPlanConfiguration": {
                    "configurationId": "3",
                    "configurationName": "mut_crash"
                }
            },
            {
                "expectedFailures": 0,
                "failedTests": 1,
                "passedTests": 0,
                "skippedTests": 0,
                "testPlanConfiguration": {
                    "configurationId": "2",
                    "configurationName": "mut_fail"
                }
            },
            {
                "expectedFailures": 0,
                "failedTests": 0,
                "passedTests": 1,
                "skippedTests": 0,
                "testPlanConfiguration": {
                    "configurationId": "1",
                    "configurationName": "mut_pass"
                }
            }
        ]
    }
    """.utf8)

    /// The same batch's `xcresulttool get test-results tests --compact`
    /// tree, shaped exactly as confirmed against real bundles: `Test Plan`
    /// → `Unit test bundle` → `Test Suite` → `Test Case` → `Test Plan
    /// Configuration` → `Failure Message`. Attribution reads only this —
    /// each configuration's own node under its own test case, never a
    /// batch-wide list matched by identifier.
    private static let capturedBatchTree = Data("""
    {
        "testNodes": [
            {
                "name": "CheckoutDemo",
                "nodeType": "Test Plan",
                "children": [
                    {
                        "name": "CheckoutTests",
                        "nodeType": "Unit test bundle",
                        "children": [
                            {
                                "name": "CheckoutTests",
                                "nodeType": "Test Suite",
                                "children": [
                                    {
                                        "name": "testCouponRequiresTwentyMinimum()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "CheckoutTests/testCouponRequiresTwentyMinimum()",
                                        "children": [
                                            {
                                                "name": "mut_pass",
                                                "nodeType": "Test Plan Configuration",
                                                "result": "Passed"
                                            }
                                        ]
                                    }
                                ]
                            },
                            {
                                "name": "AssertFailProbeTests",
                                "nodeType": "Test Suite",
                                "children": [
                                    {
                                        "name": "testFails()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "AssertFailProbeTests/testFails()",
                                        "children": [
                                            {
                                                "name": "mut_fail",
                                                "nodeType": "Test Plan Configuration",
                                                "result": "Failed",
                                                "children": [
                                                    {
                                                        "name": "XCTAssertTrue failed - intentional failure for batching PoC",
                                                        "nodeType": "Failure Message"
                                                    }
                                                ]
                                            }
                                        ]
                                    }
                                ]
                            },
                            {
                                "name": "CrashProbeTests",
                                "nodeType": "Test Suite",
                                "children": [
                                    {
                                        "name": "testCrashes()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "CrashProbeTests/testCrashes()",
                                        "children": [
                                            {
                                                "name": "mut_crash",
                                                "nodeType": "Test Plan Configuration",
                                                "result": "Failed",
                                                "children": [
                                                    {
                                                        "name": "Crash: xctest at CrashProbeTests.testCrashes()",
                                                        "nodeType": "Failure Message"
                                                    }
                                                ]
                                            }
                                        ]
                                    }
                                ]
                            }
                        ]
                    }
                ]
            }
        ]
    }
    """.utf8)

    // Shaped like `TestIdentifier.onlyTestingArgument`: "<target>/<Class>/<method>",
    // matching each Test Case node's own `nodeIdentifier`, sans the trailing "()".
    private let configurationTestIdentifiers = [
        "mut_pass": ["CheckoutTests/CheckoutTests/testCouponRequiresTwentyMinimum"],
        "mut_fail": ["CheckoutTests/AssertFailProbeTests/testFails"],
        "mut_crash": ["CheckoutTests/CrashProbeTests/testCrashes"]
    ]

    private func classify() throws -> [String: XCResultAdapter.Outcome] {
        let batch = try JSONDecoder().decode(BatchTestSummaryJSON.self, from: Self.capturedBatchSummary)
        let tree = try JSONDecoder().decode(BatchTestNodesJSON.self, from: Self.capturedBatchTree)
        return XCResultAdapter().classify(batch: batch, tree: tree, configurationTestIdentifiers: configurationTestIdentifiers)
    }

    @Test("A clean configuration is classified passed")
    func cleanConfigurationPasses() throws {
        let outcomes = try classify()
        #expect(outcomes["mut_pass"]?.status == .passed)
    }

    @Test("A plain assertion failure is classified failed, not crashed")
    func assertionFailureIsFailedNotCrashed() throws {
        let outcomes = try classify()
        #expect(outcomes["mut_fail"]?.status == .failed)
    }

    @Test("A crash is told apart from a plain failure by the Crash: prefix, per configuration")
    func crashIsDistinguishedFromFailure() throws {
        let outcomes = try classify()
        #expect(outcomes["mut_crash"]?.status == .crashed)
    }

    @Test("Failures are attributed only to their own configuration, never bleeding into a neighbor")
    func failuresDoNotCrossConfigurations() throws {
        let outcomes = try classify()

        // The crash's failure must not also count against the passing or
        // plain-failure configurations — each configuration's own subtree
        // of the per-test hierarchy is exactly the failures attributed to it.
        #expect(outcomes["mut_pass"]?.summary.failed == 0)
        #expect(outcomes["mut_fail"]?.summary.failingTests == ["CheckoutTests/AssertFailProbeTests/testFails()"])
        #expect(outcomes["mut_crash"]?.summary.failingTests == ["CheckoutTests/CrashProbeTests/testCrashes()"])
    }

    @Test("A configuration named in the request but absent from the bundle is infrastructureFailure, not dropped")
    func missingConfigurationIsInfrastructureFailure() throws {
        let batch = try JSONDecoder().decode(BatchTestSummaryJSON.self, from: Self.capturedBatchSummary)
        let tree = try JSONDecoder().decode(BatchTestNodesJSON.self, from: Self.capturedBatchTree)
        let outcomes = XCResultAdapter().classify(
            batch: batch,
            tree: tree,
            configurationTestIdentifiers: configurationTestIdentifiers.merging(
                ["mut_ghost": ["GhostTests/testGhost"]]
            ) { _, new in new }
        )

        #expect(outcomes["mut_ghost"]?.status == .infrastructureFailure)
        // The real configurations are unaffected by the phantom one.
        #expect(outcomes["mut_pass"]?.status == .passed)
    }

    /// Found against a real, much larger batch than this fixture's three
    /// configurations (a 940-mutant real-project run): a configuration can
    /// report a real, nonzero `failedTests` count while none of its own
    /// nodes in the per-test hierarchy name a failing test — the same "the
    /// runner failed for a reason with no test identifier attached" shape
    /// `isSystemFailure` recognizes for a single, unbatched mutant, just
    /// with no way to name which configuration it happened to once several
    /// are batched together. Reading an empty own-failure list as "nothing
    /// failed" here would report a proven `killedByAssertion` backed by
    /// nothing — this must fail closed instead.
    private static let unattributedFailureBatchSummary = Data("""
    {
        "devicesAndConfigurations": [
            {
                "expectedFailures": 0,
                "failedTests": 1,
                "passedTests": 25,
                "skippedTests": 0,
                "testPlanConfiguration": {
                    "configurationId": "1",
                    "configurationName": "mut_unattributed"
                }
            },
            {
                "expectedFailures": 0,
                "failedTests": 1,
                "passedTests": 1,
                "skippedTests": 0,
                "testPlanConfiguration": {
                    "configurationId": "2",
                    "configurationName": "mut_attributed"
                }
            }
        ]
    }
    """.utf8)

    /// `mut_unattributed`'s own test (`testUnattributed`) is recorded here
    /// as having passed — its one real failure came from something that
    /// produced no test-case node at all (a system-level fault), so its own
    /// subtree of the tree names no failing test even though its aggregate
    /// count says one test failed.
    private static let unattributedFailureBatchTree = Data("""
    {
        "testNodes": [
            {
                "name": "CheckoutDemo",
                "nodeType": "Test Plan",
                "children": [
                    {
                        "name": "CheckoutTests",
                        "nodeType": "Unit test bundle",
                        "children": [
                            {
                                "name": "SomeTests",
                                "nodeType": "Test Suite",
                                "children": [
                                    {
                                        "name": "testUnattributed()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "SomeTests/testUnattributed()",
                                        "children": [
                                            {
                                                "name": "mut_unattributed",
                                                "nodeType": "Test Plan Configuration",
                                                "result": "Passed"
                                            }
                                        ]
                                    },
                                    {
                                        "name": "testAttributed()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "SomeTests/testAttributed()",
                                        "children": [
                                            {
                                                "name": "mut_attributed",
                                                "nodeType": "Test Plan Configuration",
                                                "result": "Failed",
                                                "children": [
                                                    {
                                                        "name": "XCTAssertTrue failed - a real, attributable failure",
                                                        "nodeType": "Failure Message"
                                                    }
                                                ]
                                            }
                                        ]
                                    }
                                ]
                            }
                        ]
                    }
                ]
            }
        ]
    }
    """.utf8)

    @Test("A real failure count with no attributable failing test is infrastructureFailure, not a guessed kill")
    func unattributedFailureCountIsInfrastructureFailureNotAGuessedKill() throws {
        let batch = try JSONDecoder().decode(BatchTestSummaryJSON.self, from: Self.unattributedFailureBatchSummary)
        let tree = try JSONDecoder().decode(BatchTestNodesJSON.self, from: Self.unattributedFailureBatchTree)
        let outcomes = XCResultAdapter().classify(
            batch: batch,
            tree: tree,
            configurationTestIdentifiers: [
                "mut_unattributed": ["CheckoutTests/SomeTests/testUnattributed"],
                "mut_attributed": ["CheckoutTests/SomeTests/testAttributed"]
            ]
        )

        #expect(outcomes["mut_unattributed"]?.status == .infrastructureFailure)
        // The other configuration's real, attributable failure is unaffected.
        #expect(outcomes["mut_attributed"]?.status == .failed)
    }

    // MARK: - Overlapping covering-test selections (the batch-attribution bug)

    /// The bug this suite exists to pin, reproduced at fixture scale: two
    /// mutants in the same batch (`mut_a`, `mut_b`) both cover
    /// `testShared`, because `selectCoveringTests` picks covering tests
    /// per-mutant and two mutations in the same function commonly share a
    /// covering test. `testShared` genuinely fails only under `mut_a`'s own
    /// run; `mut_b`'s own run of the very same test genuinely passes.
    ///
    /// Confirmed against a real batch bundle from a 100-mutant benchmark
    /// run: under the old flat-`testFailures`-identifier-matching rule, a
    /// shared covering test failing in one configuration was also
    /// attributed to sibling configurations whose own
    /// `devicesAndConfigurations` counts showed zero failures, because the
    /// old rule could only ask "does this failing identifier appear
    /// *anywhere* in my own narrowed selection", not "did *my own* run of
    /// this test fail". The per-test hierarchy answers the second question
    /// directly, since `mut_b`'s own `Test Plan Configuration` node under
    /// `testShared` records "Passed", not "Failed".
    private static let overlappingCoveringTestSummary = Data("""
    {
        "devicesAndConfigurations": [
            {
                "expectedFailures": 0,
                "failedTests": 1,
                "passedTests": 1,
                "skippedTests": 0,
                "testPlanConfiguration": {
                    "configurationId": "1",
                    "configurationName": "mut_a"
                }
            },
            {
                "expectedFailures": 0,
                "failedTests": 0,
                "passedTests": 2,
                "skippedTests": 0,
                "testPlanConfiguration": {
                    "configurationId": "2",
                    "configurationName": "mut_b"
                }
            }
        ]
    }
    """.utf8)

    private static let overlappingCoveringTestTree = Data("""
    {
        "testNodes": [
            {
                "name": "OverlapDemo",
                "nodeType": "Test Plan",
                "children": [
                    {
                        "name": "OverlapTests",
                        "nodeType": "Unit test bundle",
                        "children": [
                            {
                                "name": "SharedSuite",
                                "nodeType": "Test Suite",
                                "children": [
                                    {
                                        "name": "testOnlyA()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "SharedSuite/testOnlyA()",
                                        "children": [
                                            {
                                                "name": "mut_a",
                                                "nodeType": "Test Plan Configuration",
                                                "result": "Passed"
                                            }
                                        ]
                                    },
                                    {
                                        "name": "testOnlyB()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "SharedSuite/testOnlyB()",
                                        "children": [
                                            {
                                                "name": "mut_b",
                                                "nodeType": "Test Plan Configuration",
                                                "result": "Passed"
                                            }
                                        ]
                                    },
                                    {
                                        "name": "testShared()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "SharedSuite/testShared()",
                                        "children": [
                                            {
                                                "name": "mut_a",
                                                "nodeType": "Test Plan Configuration",
                                                "result": "Failed",
                                                "children": [
                                                    {
                                                        "name": "XCTAssertEqual failed: (\\"1\\") is not equal to (\\"0\\")",
                                                        "nodeType": "Failure Message"
                                                    }
                                                ]
                                            },
                                            {
                                                "name": "mut_b",
                                                "nodeType": "Test Plan Configuration",
                                                "result": "Passed"
                                            }
                                        ]
                                    }
                                ]
                            }
                        ]
                    }
                ]
            }
        ]
    }
    """.utf8)

    @Test(
        """
        A shared covering test failing under one configuration's own run does not fail a sibling configuration \
        whose own run of the same test passed
        """
    )
    func sharedCoveringTestFailureDoesNotBleedIntoSiblingConfiguration() throws {
        let batch = try JSONDecoder().decode(BatchTestSummaryJSON.self, from: Self.overlappingCoveringTestSummary)
        let tree = try JSONDecoder().decode(BatchTestNodesJSON.self, from: Self.overlappingCoveringTestTree)
        let outcomes = XCResultAdapter().classify(
            batch: batch,
            tree: tree,
            configurationTestIdentifiers: [
                "mut_a": ["OverlapTests/SharedSuite/testOnlyA", "OverlapTests/SharedSuite/testShared"],
                "mut_b": ["OverlapTests/SharedSuite/testOnlyB", "OverlapTests/SharedSuite/testShared"]
            ]
        )

        // mut_a's own run of the shared test really failed: a proven kill.
        #expect(outcomes["mut_a"]?.status == .failed)
        #expect(outcomes["mut_a"]?.summary.failingTests == ["OverlapTests/SharedSuite/testShared()"])

        // mut_b's own run of the very same test genuinely passed — it must
        // not be classified as failed just because the shared identifier
        // also appears in its own narrowed selection.
        #expect(outcomes["mut_b"]?.status == .passed)
        #expect(outcomes["mut_b"]?.summary.failed == 0)
        #expect(outcomes["mut_b"]?.summary.failingTests.isEmpty == true)
    }

    // MARK: - Native XCTest timeout inside a batch (Gate 3 Phase H2)

    /// The exact A/pass, B/native-timeout, C/pass shape confirmed for real
    /// against `xcodebuild -test-timeouts-enabled YES
    /// -maximum-test-execution-time-allowance 60`
    /// (`XcodeBatchHangTimeoutSpikeAcceptanceTests`), captured here as a
    /// fast unit-level pin so the classification path doesn't need a
    /// simulator to stay covered.
    private static let nativeTimeoutBatchSummary = Data("""
    {
        "devicesAndConfigurations": [
            {
                "expectedFailures": 0,
                "failedTests": 0,
                "passedTests": 1,
                "skippedTests": 0,
                "testPlanConfiguration": { "configurationId": "1", "configurationName": "A" }
            },
            {
                "expectedFailures": 0,
                "failedTests": 1,
                "passedTests": 0,
                "skippedTests": 0,
                "testPlanConfiguration": { "configurationId": "2", "configurationName": "B" }
            },
            {
                "expectedFailures": 0,
                "failedTests": 0,
                "passedTests": 1,
                "skippedTests": 0,
                "testPlanConfiguration": { "configurationId": "3", "configurationName": "C" }
            }
        ]
    }
    """.utf8)

    private static let nativeTimeoutBatchTree = Data("""
    {
        "testNodes": [
            {
                "name": "CheckoutDemo",
                "nodeType": "Test Plan",
                "children": [
                    {
                        "name": "CheckoutTests",
                        "nodeType": "Unit test bundle",
                        "children": [
                            {
                                "name": "CheckoutTests",
                                "nodeType": "Test Suite",
                                "children": [
                                    {
                                        "name": "testCouponAboveMinimum()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "CheckoutTests/testCouponAboveMinimum()",
                                        "children": [
                                            { "name": "A", "nodeType": "Test Plan Configuration", "result": "Passed", "durationInSeconds": 0.007 }
                                        ]
                                    },
                                    {
                                        "name": "testCouponAtMinimum()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "CheckoutTests/testCouponAtMinimum()",
                                        "children": [
                                            { "name": "C", "nodeType": "Test Plan Configuration", "result": "Passed", "durationInSeconds": 0.001 }
                                        ]
                                    }
                                ]
                            },
                            {
                                "name": "HangSpikeTests",
                                "nodeType": "Test Suite",
                                "children": [
                                    {
                                        "name": "testIntentionalHang()",
                                        "nodeType": "Test Case",
                                        "nodeIdentifier": "HangSpikeTests/testIntentionalHang()",
                                        "children": [
                                            {
                                                "name": "B",
                                                "nodeType": "Test Plan Configuration",
                                                "result": "Failed",
                                                "durationInSeconds": 60,
                                                "children": [
                                                    {
                                                        "name": "Test exceeded execution time allowance of 1 minute. The test may have hung; check Xcode's test report for additional diagnostics.",
                                                        "nodeType": "Failure Message"
                                                    }
                                                ]
                                            }
                                        ]
                                    }
                                ]
                            }
                        ]
                    }
                ]
            }
        ]
    }
    """.utf8)

    @Test("A batch with one hanging configuration classifies A/passed, B/timedOut, C/passed")
    func nativeTimeoutInABatchIsClassifiedTimedOutWithoutAffectingSiblings() throws {
        let batch = try JSONDecoder().decode(BatchTestSummaryJSON.self, from: Self.nativeTimeoutBatchSummary)
        let tree = try JSONDecoder().decode(BatchTestNodesJSON.self, from: Self.nativeTimeoutBatchTree)
        let outcomes = XCResultAdapter().classify(
            batch: batch,
            tree: tree,
            configurationTestIdentifiers: [
                "A": ["CheckoutTests/CheckoutTests/testCouponAboveMinimum"],
                "B": ["CheckoutTests/HangSpikeTests/testIntentionalHang"],
                "C": ["CheckoutTests/CheckoutTests/testCouponAtMinimum"]
            ]
        )

        #expect(outcomes["A"]?.status == .passed)
        #expect(outcomes["B"]?.status == .timedOut)
        #expect(outcomes["C"]?.status == .passed)
    }
}
