import MutationModel

/// Build identity, embedded at release time.
///
/// Every plan and report records these. A result that cannot be traced back to
/// the exact toolchain that produced it is not reproducible, and reproducibility
/// is the property the whole tool is built around — so this is not decoration.
///
/// The placeholders are substituted by the release script; a development build
/// reports itself honestly as a development build rather than claiming a version
/// it does not have.
public enum ToolVersion {
    public static let version = "0.1.0-dev"

    /// Replaced at release. `nil` means "built from a working tree", which is
    /// the truthful answer for a local build.
    public static let commitSHA: String? = nil

    /// SwiftSyntax version this binary was linked against. Recorded because a
    /// SwiftSyntax change can move a node's trivia boundaries, which moves byte
    /// anchors, which changes Mutation IDs.
    ///
    /// SwiftSyntax exposes no version symbol to read this from, so it stays a
    /// literal — but an unchecked literal is the failure `planSchemaVersion`
    /// below describes, and here it is worse than a wrong `--version` line:
    /// `PlanCompatibility.check` warns that byte anchors may have moved by
    /// comparing this value in a stored plan against this value now, so a
    /// dependency bumped without bumping this compares the stale constant to
    /// itself and the warning silently never fires.
    /// `SwiftSyntaxVersionPinConsistencyTests` ties it to `Package.resolved`.
    public static let swiftSyntaxVersion = "604.0.0"

    /// Read from `SchemaVersion`, never copied. These are the same fact as
    /// the constants the plan and report writers stamp into their own files,
    /// and a second literal here is a second thing to remember: bumping
    /// `SchemaVersion.plan` while this stayed at its old value would leave
    /// `mutantkit --version` reporting a schema the tool no longer writes —
    /// a lie in the one output whose entire job is to say what this build
    /// is. Nothing tied the two before, and nothing checked them.
    ///
    /// Same reasoning `Scripts/release-build.sh` already applies to the
    /// schemata runtime ABI version, which it reads out of the C header
    /// rather than duplicating: "a hand-maintained second copy is exactly
    /// the kind of drift that would make a genuine release silently
    /// mismatch".
    public static let planSchemaVersion = SchemaVersion.plan
    public static let reportSchemaVersion = SchemaVersion.result

    public static var summary: String {
        var lines = ["mutantkit \(version)"]
        if let commitSHA {
            lines.append("commit: \(commitSHA)")
        } else {
            lines.append("commit: (development build)")
        }
        lines.append("swift-syntax: \(swiftSyntaxVersion)")
        lines.append("plan schema: \(planSchemaVersion)")
        lines.append("report schema: \(reportSchemaVersion)")
        return lines.joined(separator: "\n")
    }
}
