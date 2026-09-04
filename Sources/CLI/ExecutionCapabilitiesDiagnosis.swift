import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel

/// A `mutantkit doctor` summary section: which optional execution-
/// acceleration features this environment/project combination can
/// actually use right now.
///
/// Every line is grounded in a real, computed fact about the *current*
/// project doctor was run against — never a static, aspirational list of
/// "MutantKit supports X". Per-test coverage selection and test batching
/// are each a protocol-conformance check against the exact
/// `AppleAdapterFactory.Resolution` `ReadinessCheck.diagnose` already
/// resolved for this run (the same value a real `mutantkit run` against
/// this project would resolve). Schemata execution is *not* a protocol-
/// conformance check — see `schemataItem`'s own doc comment for why — it
/// is sourced from `docs/schemata-support-matrix.md`'s own supported/
/// unsupported table plus the resolved `Configuration`, the same two
/// inputs a real run actually depends on. (The shared module cache line
/// lives in `DoctorCommand.sharedModuleCacheDiagnosis` instead, appended
/// after `ReadinessCheck.diagnose` returns — see that function's own doc
/// comment for why it stays separate.)
enum ExecutionCapabilitiesDiagnosis {
    static func items(for resolution: AppleAdapterFactory.Resolution, configuration: Configuration) -> [DiagnosisItem] {
        [
            schemataItem(kind: resolution.detection.kind, adapter: resolution.adapter, configuration: configuration),
            perTestCoverageItem(adapter: resolution.adapter),
            testBatchingItem(adapter: resolution.adapter)
        ]
    }

    // MARK: - Schemata execution

    /// `docs/schemata-support-matrix.md`'s own supported/unsupported
    /// column, as executable code — the *only* place that answers "does
    /// this project kind support schemata" for `doctor`.
    ///
    /// Deliberately **not** derived from `adapter.build is SchemataBuildable
    /// && adapter.test is SchemataTestable` (the check `SchemataRunOrchestration
    /// .run` itself uses to fail closed at run time — see its own
    /// `OrchestrationError.adapterNotSchemataCapable` guard): that pair is
    /// necessary but not sufficient. `AppleAdapterFactory.adapter(for:)`
    /// maps `.swiftPackageApple`, `.xcodeProject` *and* `.xcodeWorkspace`
    /// all to the same `XcodeBuildProjectAdapter`/`XcodeBuildAdapter`
    /// pair, whose `build`/`test` conform to `SchemataBuildable`/
    /// `SchemataTestable` regardless of which of those three kinds is
    /// actually in play — so the conformance check alone reports
    /// "available" for `swiftPackageApple` and `xcodeWorkspace` too,
    /// directly contradicting the matrix's own Unsupported rows for both
    /// (a build-settings-resolution failure for `swiftPackageApple`, an
    /// entirely unimplemented target-resolution case for `xcodeWorkspace`
    /// — see the matrix doc's "Why the two unsupported rows are
    /// unsupported" section). Update this switch and the matrix doc
    /// together; they must never say different things.
    static func schemataSupported(for kind: ProjectKind) -> Bool {
        switch kind {
        case .swiftPackageMacOS, .xcodeProject:
            true
        case .swiftPackageApple, .xcodeWorkspace, .auto:
            false
        }
    }

    /// Sources availability from `schemataSupported(for:)` (the matrix's
    /// own kind-level answer) and, for a kind the matrix marks Supported,
    /// from what a real `mutantkit run` against `configuration` would
    /// actually resolve: `RunCommand.resolveTestAdapter` wraps the base
    /// test adapter in `PrioritizingTestAdapter` — `TestSelecting`-only,
    /// not `SchemataTestable` — whenever `execution.selectCoveringTests`
    /// and `execution.earlyAbortSelectedTests` are both on and batching
    /// isn't taking over instead. `PrioritizingTestAdapter.wouldWrap` is
    /// the exact predicate `resolveTestAdapter` itself evaluates, reused
    /// here rather than re-derived, so the two can never disagree about
    /// which test adapter a real run ends up with.
    private static func schemataItem(kind: ProjectKind, adapter: any ProjectAdapter, configuration: Configuration) -> DiagnosisItem {
        guard schemataSupported(for: kind) else {
            return DiagnosisItem(
                name: "Schemata execution",
                status: .warning,
                code: .schemataExecutionSupport,
                detail: "not available for \(kind.rawValue) in this release",
                remedy: "Mutations will run in isolated mode (one build per mutant)."
                    + " Schemata (shared-build) execution currently ships for SwiftPM/macOS projects and"
                    + " Xcode-project/iOS-Simulator projects only — see docs/schemata-support-matrix.md."
            )
        }

        guard !PrioritizingTestAdapter.wouldWrap(configuration, base: adapter.test) else {
            return DiagnosisItem(
                name: "Schemata execution",
                status: .warning,
                code: .schemataExecutionSupport,
                detail: "not available for this run's configuration — execution.selectCoveringTests and"
                    + " execution.earlyAbortSelectedTests together wrap the test adapter in a selected-test-only"
                    + " adapter that cannot run schemata (see RunCommand.resolveTestAdapter)",
                remedy: "Disable execution.selectCoveringTests or execution.earlyAbortSelectedTests, or set"
                    + " execution.testBatchSize with an adapter that supports batching, to keep schemata execution"
                    + " available for this \(kind.rawValue) project."
            )
        }

        return DiagnosisItem(
            name: "Schemata execution",
            status: .ok,
            code: .schemataExecutionSupport,
            detail: "available for this \(kind.rawValue) project"
        )
    }

    // MARK: - Per-test coverage selection

    /// `TestSelecting` conformance is exactly what `execution
    /// .selectCoveringTests` needs from the resolved test adapter — see
    /// that protocol's own doc comment ("an adapter that cannot (or was
    /// not asked to) produce this attribution simply does not conform").
    private static func perTestCoverageItem(adapter: any ProjectAdapter) -> DiagnosisItem {
        let supported = adapter.test is TestSelecting
        return DiagnosisItem(
            name: "Per-test coverage selection",
            status: supported ? .ok : .warning,
            code: .perTestCoverageSupport,
            detail: supported
                ? "available — execution.selectCoveringTests: true narrows each mutant to its covering tests"
                : "not available for this project's resolved test adapter",
            remedy: supported
                ? nil
                : "Every mutant will run the full configured test list; execution.selectCoveringTests would have no effect."
        )
    }

    // MARK: - Test batching

    /// Two independent conformances cover the two execution backends:
    /// `BatchTestable` for isolated mode, `SchemataBatchTestable` for
    /// schemata mode (a refinement of `SchemataTestable`, so it can only
    /// ever be true alongside `schemataItem`'s own `supported`). Reported
    /// as one line — `execution.testBatchSize` is one setting regardless
    /// of which backend ends up honouring it.
    private static func testBatchingItem(adapter: any ProjectAdapter) -> DiagnosisItem {
        let schemataBatching = adapter.test is SchemataBatchTestable
        let isolatedBatching = adapter.test is BatchTestable
        let supported = schemataBatching || isolatedBatching
        let detail =
            if schemataBatching {
                "available (schemata token batching) — set execution.testBatchSize to enable"
            } else if isolatedBatching {
                "available (isolated-mode batching) — set execution.testBatchSize to enable"
            } else {
                "not available for this project's resolved test adapter"
            }
        return DiagnosisItem(
            name: "Test batching",
            status: supported ? .ok : .warning,
            code: .testBatchingSupport,
            detail: detail,
            remedy: supported ? nil : "execution.testBatchSize would have no effect on this project."
        )
    }
}
