import MutationModel

/// The canonical machine-readable report: `RunReport` itself, nothing added and
/// nothing summarised away.
///
/// Every other format is a lossy view for a particular audience. This one is the
/// record — `inspect`, `reproduce` and any downstream tooling read it back, so
/// it must round-trip exactly and stay byte-identical across runs with identical
/// input. That is why it reuses `MutationPlan.encoder()` rather than configuring
/// its own: one spelling of "canonical JSON" for every artifact the tool writes.
public struct JSONReporter: Reporter {
    public init() {}

    public func render(_ report: RunReport) throws -> String {
        // No fail-closed special case is needed or wanted here: `score` is
        // already `nil` in the model, and it encodes as an absent key. A
        // consumer that wants a number must handle its absence, which is exactly
        // the contract we want to force on them.
        String(decoding: try report.encoded(), as: UTF8.self)
    }
}
