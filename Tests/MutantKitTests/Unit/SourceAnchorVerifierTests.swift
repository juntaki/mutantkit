import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// The anchor is the only thing standing between "apply the plan" and "write
/// bytes at an offset that now means something else".
///
/// Every rejection here has to stay a rejection. The failure mode being guarded
/// against is not a crash — it is a plausible-looking run in which the tool
/// spliced text into the wrong expression and reported a score anyway.
@Suite("Source anchor verification")
struct SourceAnchorVerifierTests {
    private static let source = """
    struct Cart {
        func isReady() -> Bool { return true }
    }
    """

    private func anchoredPoint() throws -> (point: MutationPoint, data: Data) {
        let points = try discover(Self.source, path: "Sources/Cart.swift", using: Operators.boolLiteral)
        return (points[0], Data(Self.source.utf8))
    }

    @Test("A valid point verifies against the source it was discovered in")
    func validPointVerifies() throws {
        let (point, data) = try anchoredPoint()

        for depth in [SourceAnchorVerifier.Depth.content, .full] {
            let verification = SourceAnchorVerifier.verify(point, against: data, depth: depth)
            #expect(verification.isValid)
            #expect(verification.failures.isEmpty)
            #expect(verification.diagnosis == "anchor verified")
        }
    }

    /// A file that changed after planning is the ordinary case, not an exotic
    /// one: someone edits while a run is in flight. The recorded offsets now
    /// point at whatever moved into their place, so the only safe answer is to
    /// refuse.
    @Test("A file edited after planning is rejected rather than spliced at a shifted offset")
    func editedFileIsRejected() throws {
        let (point, _) = try anchoredPoint()

        let shifted = """
        // A comment inserted above everything shifts every byte offset below it.
        struct Cart {
            func isReady() -> Bool { return true }
        }
        """
        let verification = SourceAnchorVerifier.verify(point, against: Data(shifted.utf8), depth: .content)

        #expect(!verification.isValid)
        #expect(verification.failureNames.contains("fileHashMismatch"))
        // The recorded range now covers something else entirely — proof that a
        // hash check alone is what stopped a wrong-offset write.
        #expect(verification.failureNames.contains("originalTextMismatch"))
    }

    @Test("A changed file reports the exact hash it expected")
    func hashMismatchNamesBothHashes() throws {
        let (point, _) = try anchoredPoint()
        let edited = Self.source + "\n// trailing edit\n"

        let verification = SourceAnchorVerifier.verify(point, against: Data(edited.utf8), depth: .content)

        let expectedHash = ContentHash.of(Data(Self.source.utf8))
        let actualHash = ContentHash.of(Data(edited.utf8))
        #expect(verification.failures.contains(.fileHashMismatch(expected: expectedHash, actual: actualHash)))
        #expect(point.sourceFileHash == expectedHash)
    }

    /// The range is still in bounds and still the same length — only the text
    /// under it changed. Without this check the splice would compile, and the
    /// mutant would be a lie rather than a crash.
    @Test("A range that now covers different text is rejected")
    func changedTextUnderTheRangeIsRejected() throws {
        let (point, _) = try anchoredPoint()

        // `true` and `fals` are both four bytes, so the range stays valid and
        // only its contents differ.
        let retyped = Self.source.replacingOccurrences(of: "return true", with: "return fals")
        let verification = SourceAnchorVerifier.verify(point, against: Data(retyped.utf8), depth: .content)

        #expect(!verification.isValid)
        #expect(verification.failures.contains(.originalTextMismatch(expected: "true", found: "fals")))
    }

    @Test("A range beyond the end of the file is rejected")
    func rangeBeyondEndOfFileIsRejected() throws {
        let (point, data) = try anchoredPoint()
        let beyond = point.with(utf8Range: ByteRange(start: data.count + 10, end: data.count + 14))

        let verification = SourceAnchorVerifier.verify(beyond, against: data, depth: .full)

        // The hash still matches — this is purely a bounds failure, and it stops
        // there rather than reading past the end to compare text.
        #expect(verification.failureNames == ["rangeOutOfBounds"])
        #expect(verification.failures.contains(
            .rangeOutOfBounds(range: beyond.utf8Range, fileLength: data.count)
        ))
    }

    /// `.content` is documented as hash plus exact original text; `.full`
    /// additionally re-parses to re-check kind, fingerprints and declaration.
    /// Renaming the enclosing type to another name of the same length keeps the
    /// anchor text byte-identical at the same offset, so the edit is invisible
    /// to `.content` beyond the hash and described precisely by `.full`.
    @Test("Content depth checks bytes; full depth additionally re-parses")
    func depthsDifferAsDocumented() throws {
        let (point, _) = try anchoredPoint()

        let renamed = Self.source.replacingOccurrences(of: "struct Cart", with: "struct Card")
        let renamedData = Data(renamed.utf8)
        #expect(renamed.utf8.count == Self.source.utf8.count, "the rename must not move the anchor")

        let content = SourceAnchorVerifier.verify(point, against: renamedData, depth: .content)
        #expect(content.failureNames == ["fileHashMismatch"])

        let full = SourceAnchorVerifier.verify(point, against: renamedData, depth: .full)
        #expect(full.failureNames == ["fileHashMismatch", "declarationMismatch"])
        #expect(full.failures.contains(
            .declarationMismatch(expected: "Cart.isReady()", actual: "Card.isReady()")
        ))
    }

    /// Re-parsing is safe here in the way it was not for a node-identity design:
    /// nothing is matched by identity, so a fresh parse of identical bytes
    /// necessarily agrees with discovery.
    @Test("Full-depth verification succeeds after the discovery tree is gone")
    func fullDepthAgreesWithDiscoveryAcrossAParseBoundary() throws {
        let source = try Fixture.text("RealisticViewModel")
        let data = Data(source.utf8)
        let points = try discover(source, path: "Sources/CartViewModel.swift")

        #expect(!points.isEmpty)
        for point in points {
            let verification = SourceAnchorVerifier.verify(point, against: data, depth: .full)
            #expect(verification.isValid, "\(point.displayLocation): \(verification.diagnosis)")
        }
    }

    /// Found by this project's own P7 self-mutation audit
    /// (`Research/mutation-testing-hardening-2026-08/PROGRESS.md`):
    /// `matchedNode` re-implements `verify`'s own `range.end <= bytes.count`
    /// bounds guard independently (line 152 vs. line 86) rather than sharing
    /// it, and nothing exercised the boundary where a mutation's range ends
    /// on the file's very last byte. Mutating that guard's `<=` to `<`
    /// survived the whole suite untouched — every schemata lowerer that
    /// calls `matchedNode` (`Sources/SwiftCoreOperators/*SchemataLowerer.swift`)
    /// would silently fall back to isolated execution for any mutation
    /// candidate whose range happens to reach exactly to EOF, with nothing
    /// to say so.
    @Test("matchedNode accepts a point whose range ends on the file's exact last byte")
    func matchedNodeFindsAPointAtTheExactEndOfFile() throws {
        // No trailing newline: the discovered `true` literal's range ends
        // exactly at `data.count`, the boundary `verify`/`matchedNode`'s
        // bounds guards must both treat as in-range.
        let source = "let flag = true"
        let points = try discover(source, using: Operators.boolLiteral)
        let point = try #require(points.first)
        let data = Data(source.utf8)

        #expect(
            point.utf8Range.end == data.count,
            "fixture must place the mutation's end exactly at EOF for this regression to be meaningful"
        )

        let node = SourceAnchorVerifier.matchedNode(for: point, in: data)
        #expect(node != nil, "a range ending exactly at EOF is in bounds, not out of bounds")
    }

    @Test("A rejected anchor explains itself in one sentence")
    func rejectionProducesAReadableDiagnosis() throws {
        let (point, _) = try anchoredPoint()
        let edited = Self.source + "\n// trailing edit\n"

        let verification = SourceAnchorVerifier.verify(point, against: Data(edited.utf8), depth: .content)

        #expect(verification.diagnosis.hasPrefix("Anchor rejected: "))
        #expect(verification.diagnosis.hasSuffix("."))
        #expect(verification.diagnosis.contains("the file changed since planning"))
    }
}
