//
// Extracted from `XcodeBuildAdapter.swift` as part of this project's
// internal execution-engine restructuring (see its own, private planning
// notes, not part of this public repo, for the full rationale). Collapses
// the three near-duplicate
// device-selection-and-lease blocks `leaseAndRunTests`,
// `leaseAndRunSchemataToken`, and `runBatchTests`'s own inline block each
// carried, into one method.
//
// **Plan §5.1's asymmetry, preserved by construction, not by convention**:
// `workerDevicesByWorkspace` is honored by exactly one of the three original
// call sites (`leaseAndRunTests`, isolated mode only) — neither the
// schemata-token nor the batch path ever checked it. This type does not
// memoize or rediscover that fact; it takes `preferredDevice` as an explicit
// per-call parameter, so the isolated caller passes
// `workerDevicesByWorkspace?[workspace.lastPathComponent]` and the other two
// pass `nil` — reproducing each caller's exact current behavior, visible at
// every call site rather than implicit in which block happens to check a
// dictionary. See `XcodeBuildAdapter`'s three call sites for the mapping.
//
// **Structural Invariant 2 (fail-closed uninstall) interaction**: none. This
// type only wraps lease acquisition/release around whatever `run` does —
// exactly as `SimulatorPool.withLease(udid:)`/`(matching:)` already did
// inline at each of the three original call sites. The uninstall-then-invoke
// sequencing decision itself lives entirely inside the `run` closure each
// caller supplies (the still-unmoved choke-point methods,
// `runTestsAfterUninstall`/`runSchemataTokenAfterUninstall`) — this
// coordinator has no visibility into what `run` does and cannot skip it.
//
// **Structural Invariant 1 (build never leases) interaction**: none — this
// type is held and called only by `TestAdapter`/`SchemataTestable`/
// `BatchTestable` call sites on `XcodeBuildAdapter`; `build(in:...)` neither
// stores nor calls it.
//
// No behavior change: the three-case fallback order (preferred device,
// resolved destination's device, raw-destination `id=`, name hint) and which
// `SimulatorPool.withLease` overload each case calls are identical to the
// code this replaced.
//

/// The device-selection-and-lease concern shared (near-duplicated, not
/// shared, before this step) by `XcodeBuildAdapter`'s isolated, schemata-token,
/// and batch test paths. See this file's own header comment for the §5.1
/// asymmetry this type's `preferredDevice` parameter exists to preserve.
struct SimulatorLeaseCoordinator: Sendable {
    let simulators: SimulatorPool
    /// The destination resolved once, at run start — see `DestinationResolver`.
    /// `nil` reproduces the original per-call `resolvedDestination?.device`
    /// fallback finding nothing, exactly as before this step.
    let resolvedDestination: ResolvedDestination?

    /// Leases the device this call's tests must land on, runs `run`, and
    /// always releases it (via `SimulatorPool.withLease`, even on throw or
    /// cancellation).
    ///
    /// Four cases, most to least specific — identical order and content to
    /// each of the three original inline blocks:
    /// - `preferredDevice`, when non-nil: lease that exact UDID. This is
    ///   `workerDevicesByWorkspace`'s own precedence (see this file's header
    ///   comment) — only `leaseAndRunTests` ever passes a non-nil value here;
    ///   `leaseAndRunSchemataToken` and `runBatchTests` always pass `nil`,
    ///   which skips straight to the next case, reproducing their exact
    ///   current behavior.
    /// - `resolvedDestination` names a concrete device: lease that exact
    ///   UDID.
    /// - `rawDestination` is already pinned to `id=`: lease that exact UDID.
    /// - Otherwise, the original name-hint behavior: lease the device
    ///   `rawDestination`'s `name=` field asks for.
    /// - Parameter rawDestination: the caller's own `destination()` string —
    ///   passed in, not recomputed here, since `XcodeBuildAdapter.destination()`
    ///   depends on adapter state (`configuration`, `kind`) this type does
    ///   not have.
    func withLease<T: Sendable>(
        preferredDevice: SimulatorDevice?,
        rawDestination: String,
        run: @Sendable (SimulatorLease) async throws -> T
    ) async throws -> T {
        if let preferredDevice {
            return try await simulators.withLease(udid: preferredDevice.udid, run)
        }
        if let device = resolvedDestination?.device {
            return try await simulators.withLease(udid: device.udid, run)
        }
        if let udid = XcodeBuildAdapter.udid(inDestination: rawDestination) {
            return try await simulators.withLease(udid: udid, run)
        }
        let hint = XcodeBuildAdapter.deviceName(inDestination: rawDestination)
        return try await simulators.withLease(matching: hint, run)
    }
}
