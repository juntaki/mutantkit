import Foundation
import MutationExecution
import MutationModel
import Testing

/// Every sandbox path must have the same length.
///
/// This looks like a cosmetic detail and is not. The absolute build path reaches
/// the compiled output, so the *length* of a sandbox's path changes the emitted
/// code even when the source is byte-identical. Measured on this toolchain:
/// identical sources built at two equal-length paths produce identical
/// `__TEXT,__text`; at different-length paths they do not.
///
/// Activation evidence compares a mutant's compiled code against the baseline's.
/// The original naming — `baseline` for the baseline, `mut_<16 hex>` for mutants
/// — made those paths different lengths, so the comparison reported "differs"
/// for every mutant purely because of the path. `buildProductIdenticalToBaseline`
/// could never fire, the phantom check was dead, and every mutant carried a
/// false proof that it had reached the binary.
///
/// A false proof is worse than no proof: it is the exact failure this tool
/// exists to make impossible, wearing the badge of the mechanism meant to
/// prevent it.
@Suite("Regression: sandbox paths are equal length")
struct SandboxPathLengthTests {
    /// The real ids a run uses: one baseline, several mutants.
    private static let realWorldIDs = [
        "baseline",
        "mut_0123456789abcdef",
        "mut_fedcba9876543210",
        "reproduce",
        "a",
        String(repeating: "x", count: 200)
    ]

    @Test("Sandbox directory names are all the same length, whatever the id")
    func directoryNamesAreFixedWidth() {
        let widths = Set(Self.realWorldIDs.map { WorkspaceManager.directoryName(for: $0).count })
        #expect(widths.count == 1, "every sandbox name must be one width; got \(widths.sorted())")
    }

    /// The specific pairing that was broken: baseline against a mutant.
    @Test("The baseline's sandbox name is the same length as a mutant's")
    func baselineMatchesMutantWidth() {
        #expect(
            WorkspaceManager.directoryName(for: "baseline").count
                == WorkspaceManager.directoryName(for: "mut_0123456789abcdef").count
        )
    }

    @Test("Distinct ids get distinct sandboxes")
    func distinctIDsDoNotCollide() {
        let names = Self.realWorldIDs.map { WorkspaceManager.directoryName(for: $0) }
        #expect(Set(names).count == names.count)
    }

    /// `reproduce` hands out a path a human is told to go and look at, and a
    /// resumed run must land on the sandbox it left behind.
    @Test("The same id always maps to the same sandbox")
    func namingIsDeterministic() {
        #expect(
            WorkspaceManager.directoryName(for: "mut_0123456789abcdef")
                == WorkspaceManager.directoryName(for: "mut_0123456789abcdef")
        )
    }

    /// The name is used as a single path component, so it must not be able to
    /// carry a separator or a traversal out of the scratch root.
    @Test("A hostile id cannot escape its path component")
    func namingIsPathSafe() {
        for hostile in ["../../etc/passwd", "a/b", "..", "."] {
            let name = WorkspaceManager.directoryName(for: hostile)
            #expect(!name.contains("/"))
            #expect(!name.contains(".."))
        }
    }
}
