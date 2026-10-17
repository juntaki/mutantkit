@testable import AppleBuildAdapters
import Foundation
import Testing

/// `__TEXT,__cstring` is in the semantic hash (v3): a mutation confined to a string
/// literal changes nothing else, and an "identical product" verdict there silently dropped a
/// real mutant from the score as `notMaterialized`. The section also carries `#file`
/// paths, so the build workspace root is normalized away — and only that.
@Suite("Mach-O __cstring hash")
struct MachOCStringHashTests {
    private let rootA = URL(fileURLWithPath: "/private/tmp/mk-sandbox-aaaa")
    private let rootB = URL(fileURLWithPath: "/private/tmp/mk-sandbox-bbbb")

    private func hash(_ strings: [String], root: URL) throws -> String {
        try #require(MachOCodeHash.codeHash(of: MinimalMachOCString.build(strings: strings), workspaceRoot: root))
    }

    @Test("Same source built in two equal-length sandboxes hashes the same")
    func equalLengthSandboxesMatch() throws {
        let a = try hash(["hello", "/private/tmp/mk-sandbox-aaaa/Sources/M/F.swift"], root: rootA)
        let b = try hash(["hello", "/private/tmp/mk-sandbox-bbbb/Sources/M/F.swift"], root: rootB)
        #expect(a == b)
    }

    @Test("Only #file differing by sandbox path still hashes the same, also via /var symlink spelling")
    func fileLiteralOnly() throws {
        let a = try hash(["x", "/private/tmp/mk-sandbox-aaaa/.build/checkouts/p/S.swift"], root: rootA)
        let b = try hash(["x", "/private/tmp/mk-sandbox-bbbb/.build/checkouts/p/S.swift"], root: rootB)
        #expect(a == b)
    }

    @Test("Changing an ordinary string literal changes the hash")
    func ordinaryLiteralChange() throws {
        let a = try hash(["alpha", "beta"], root: rootA)
        let b = try hash(["alpha", "gamma"], root: rootA)
        #expect(a != b)
    }

    @Test("Swapping the two branches of a ternary of string literals changes the hash")
    func ternaryBranchSwap() throws {
        let original = try hash(["> 0", "= 0"], root: rootA)
        let swapped = try hash(["= 0", "> 0"], root: rootA)
        #expect(original != swapped)
    }

    @Test("A user's own absolute path is not normalized away")
    func userAbsolutePathIsKept() throws {
        let a = try hash(["/foo/bar"], root: rootA)
        let b = try hash(["/foo/baz"], root: rootA)
        #expect(a != b)
    }

    @Test("A different path sharing the workspace root as a prefix is not normalized")
    func lookalikePrefixIsKept() throws {
        let a = try hash(["/private/tmp/mk-sandbox-aaaaX/f"], root: rootA)
        let b = try hash(["/private/tmp/mk-sandbox-bbbbX/f"], root: rootB)
        #expect(a != b)
    }

    @Test("An unusable workspace root fails closed")
    func unusableRootFailsClosed() {
        let data = MinimalMachOCString.build(strings: ["x"])
        #expect(MachOCodeHash.codeHash(of: data, workspaceRoot: URL(fileURLWithPath: "/")) == nil)
    }
}
