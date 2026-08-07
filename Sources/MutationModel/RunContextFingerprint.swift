import Foundation

/// A hash of everything a checkpoint's cached result depends on: the plan
/// being executed, the mutantkit configuration, the toolchain, and the state of
/// every file git can see in the project — tracked or untracked.
///
/// A checkpoint exists to survive an interruption *within* one continuous
/// attempt at a run, not to survive a change to what is being tested.
/// Reusing a mutant's cached verdict after the source, the test suite, a
/// fixture, or the toolchain changed since it was recorded is exactly the
/// kind of plausible-looking-but-wrong result this tool exists to refuse —
/// the same failure shape as `mutationNotActivated`, just entering through
/// the checkpoint instead of the build. Found the hard way: a before/after
/// comparison that added a test file and restored a deleted fixture between
/// two runs of the identical plan reused a partial checkpoint from the first
/// attempt in the second, and while that particular reuse turned out to be
/// safe (the fix was already in place before either attempt started), the
/// checkpoint had no way to know that — it would have been just as willing
/// to resume across a source change that mattered.
///
/// This value is folded into the checkpoint file's *name*
/// (`RunContextProbe`, `Sources/CLI`), not stored as a field inside it: any
/// change produces a different file, so there is no code path where a stale
/// entry is read, checked against the current fingerprint, and discarded —
/// it is simply never found in the first place.
public struct RunContextFingerprint: Codable, Sendable, Hashable {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    /// A short, filesystem-safe identifier derived from `value`, for a
    /// checkpoint file name.
    public var shortDigest: String {
        ContentHash.shortDigest(of: value)
    }
}
