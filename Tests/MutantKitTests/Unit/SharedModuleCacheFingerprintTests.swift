import Foundation
@testable import MutationExecution
import Testing

/// Fast, no-subprocess coverage for `SharedModuleCacheFingerprint`'s own
/// hashing contract — namespacing the shared module cache directory by a
/// toolchain fingerprint only protects anything if the digest actually
/// changes whenever any one of the four real, queried values would (see
/// `ToolchainCacheFingerprintProbe`'s own doc comment for why those four
/// specifically), and is otherwise perfectly reproducible for the identical
/// toolchain — both directions pinned here directly, without spawning
/// `swift`/`xcodebuild`.
@Suite("SharedModuleCacheFingerprint: digest hashing contract")
struct SharedModuleCacheFingerprintTests {
    private static func fingerprint(
        swiftVersion: String = "swift-1",
        xcodeVersion: String = "xcode-1",
        sdkVersion: String = "sdk-1",
        targetTriple: String = "triple-1"
    ) -> SharedModuleCacheFingerprint {
        SharedModuleCacheFingerprint(
            swiftVersion: swiftVersion, xcodeVersion: xcodeVersion, sdkVersion: sdkVersion, targetTriple: targetTriple
        )
    }

    @Test("Identical fields produce the identical digest — reproducible across two separate values, not just one instance reused")
    func identicalFieldsProduceIdenticalDigest() {
        #expect(Self.fingerprint().digest == Self.fingerprint().digest)
    }

    @Test("Changing swiftVersion alone changes the digest")
    func swiftVersionChangesDigest() {
        #expect(Self.fingerprint().digest != Self.fingerprint(swiftVersion: "swift-2").digest)
    }

    @Test("Changing xcodeVersion alone changes the digest")
    func xcodeVersionChangesDigest() {
        #expect(Self.fingerprint().digest != Self.fingerprint(xcodeVersion: "xcode-2").digest)
    }

    @Test("Changing sdkVersion alone changes the digest")
    func sdkVersionChangesDigest() {
        #expect(Self.fingerprint().digest != Self.fingerprint(sdkVersion: "sdk-2").digest)
    }

    @Test("Changing targetTriple alone changes the digest -- the axis a universal toolchain under Rosetta needs")
    func targetTripleChangesDigest() {
        #expect(Self.fingerprint().digest != Self.fingerprint(targetTriple: "triple-2").digest)
    }

    /// Guards against a field-concatenation bug that would let two
    /// genuinely different fingerprints collide (e.g. no separator, so
    /// `swift="ab", xcode="c"` and `swift="a", xcode="bc"` hash identically)
    /// — `canonicalDescription`'s own labeled, delimited format is what
    /// this pins.
    @Test("Values shifted across a field boundary do not collide")
    func fieldBoundaryShiftDoesNotCollide() {
        let a = SharedModuleCacheFingerprint(swiftVersion: "ab", xcodeVersion: "c", sdkVersion: "sdk-1", targetTriple: "triple-1")
        let b = SharedModuleCacheFingerprint(swiftVersion: "a", xcodeVersion: "bc", sdkVersion: "sdk-1", targetTriple: "triple-1")
        #expect(a.digest != b.digest)
    }

    @Test("The digest is a fixed-length hex string safe to use as a directory-name suffix")
    func digestIsFixedLengthHex() {
        let digest = Self.fingerprint().digest
        #expect(digest.count == 16)
        #expect(digest.allSatisfy { $0.isHexDigit })
    }
}

/// Fast, no-subprocess coverage for `WorkspaceManager`'s fingerprinted
/// module-cache path helpers — pure path construction, pinned separately
/// from the real, subprocess-backed fingerprinting above.
@Suite("WorkspaceManager: fingerprinted module cache path")
struct WorkspaceManagerModuleCachePathTests {
    @Test("moduleCacheDirectoryName(forFingerprint:) namespaces the fixed dot-prefixed name by the given digest")
    func directoryNameIsNamespacedByFingerprint() {
        #expect(WorkspaceManager.moduleCacheDirectoryName(forFingerprint: "deadbeef") == ".module-cache-deadbeef")
    }

    @Test("Two different fingerprints never produce the same directory name")
    func differentFingerprintsProduceDifferentDirectoryNames() {
        #expect(
            WorkspaceManager.moduleCacheDirectoryName(forFingerprint: "aaaa")
                != WorkspaceManager.moduleCacheDirectoryName(forFingerprint: "bbbb")
        )
    }

    @Test("moduleCachePath(forSandbox:fingerprint:) resolves one path component above the sandbox, namespaced by fingerprint")
    func pathForSandboxResolvesAboveSandboxNamespacedByFingerprint() {
        let scratchRoot = URL(fileURLWithPath: "/tmp/example-scratch-root")
        let sandbox = scratchRoot.appendingPathComponent("sbx_deadbeefdeadbeefdead")
        let resolved = WorkspaceManager.moduleCachePath(forSandbox: sandbox, fingerprint: "cafef00d")

        #expect(resolved.deletingLastPathComponent().path == scratchRoot.path)
        #expect(resolved.lastPathComponent == ".module-cache-cafef00d")
    }

    @Test("underScratchRoot: and forSandbox: resolve the identical path for a sandbox directly under that root")
    func underScratchRootAgreesWithForSandbox() {
        let scratchRoot = URL(fileURLWithPath: "/tmp/example-scratch-root")
        let sandbox = scratchRoot.appendingPathComponent("sbx_deadbeefdeadbeefdead")

        let viaSandbox = WorkspaceManager.moduleCachePath(forSandbox: sandbox, fingerprint: "cafef00d")
        let viaScratchRoot = WorkspaceManager.moduleCachePath(underScratchRoot: scratchRoot, fingerprint: "cafef00d")

        #expect(viaSandbox.path == viaScratchRoot.path)
    }
}
