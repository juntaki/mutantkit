import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Applying a mutation is a byte splice and nothing more. These tests pin down
/// that it stays that way: exactly the planned bytes change, the result is still
/// a Swift program, and a source that has moved on gets a refusal instead of a
/// corrupted file.
@Suite("Mutation application")
struct MutationApplicationTests {
    private static let source = """
    struct Cart {
        var isOpen = true

        func isReady() -> Bool { return true }
    }
    """

    @Test("Applying changes only the bytes inside the planned range")
    func onlyTheMutatedRangeChanges() throws {
        let data = Data(Self.source.utf8)
        let points = try discover(Self.source, path: "Sources/Cart.swift", using: Operators.boolLiteral)

        for point in points {
            let applied = try MutationApplication.apply(point, to: data)

            let before = [UInt8](data)
            let after = [UInt8](applied.mutatedSource)
            let range = point.utf8Range

            // Everything before the range is untouched.
            #expect(Array(before[0 ..< range.start]) == Array(after[0 ..< range.start]))

            // The replacement occupies exactly the planned range.
            let delta = point.replacementText.utf8.count - point.originalText.utf8.count
            let replaced = Array(after[range.start ..< range.end + delta])
            #expect(replaced == Array(point.replacementText.utf8))

            // Everything after the range is untouched, allowing for the shift the
            // splice itself introduced.
            #expect(Array(before[range.end...]) == Array(after[(range.end + delta)...]))
        }
    }

    @Test("The mutated source is still a valid Swift program")
    func mutatedOutputStillParses() throws {
        let data = Data(Self.source.utf8)
        let points = try discover(Self.source, path: "Sources/Cart.swift")

        #expect(!points.isEmpty)
        for point in points {
            let applied = try MutationApplication.apply(point, to: data)
            #expect(
                parsesWithoutError(applied.mutatedSource),
                "\(point.originalText) -> \(point.replacementText) produced source that does not parse"
            )
        }
    }

    /// Refusing is the entire point. A tool that applies to a file it does not
    /// recognise produces either invalid Swift or — far worse — valid Swift that
    /// mutates something nobody planned.
    @Test("Applying to changed source throws instead of corrupting the file")
    func applyingToChangedSourceThrows() throws {
        let points = try discover(Self.source, path: "Sources/Cart.swift", using: Operators.boolLiteral)
        let point = points[0]

        let changed = """
        // An edit that arrived after the plan was written.
        struct Cart {
            var isOpen = true

            func isReady() -> Bool { return true }
        }
        """

        #expect(throws: ApplicationError.self) {
            try MutationApplication.apply(point, to: Data(changed.utf8))
        }

        // And the refusal is diagnosable, not just a thrown error: this is what
        // becomes a `notApplied` result rather than a silent `survived`.
        do {
            _ = try MutationApplication.apply(point, to: Data(changed.utf8))
            Issue.record("expected the anchor to be rejected")
        } catch let error as ApplicationError {
            #expect(error.verification != nil)
            #expect(error.verification?.isValid == false)
            #expect(error.description.contains("Anchor rejected"))
        }
    }

    @Test("Application produces evidence that proves it happened")
    func applicationProducesProof() throws {
        let data = Data(Self.source.utf8)
        let point = try discover(Self.source, path: "Sources/Cart.swift", using: Operators.boolLiteral)[0]

        let applied = try MutationApplication.apply(point, to: data)
        let evidence = applied.evidence

        #expect(evidence.provesSourceApplication)
        #expect(evidence.sourceBeforeHash != evidence.sourceAfterHash)
        #expect(evidence.sourceBeforeHash == ContentHash.of(data))
        #expect(evidence.sourceAfterHash == ContentHash.of(applied.mutatedSource))
        #expect(!evidence.sourceDiff.isEmpty)
        // The before-hash is what the plan anchored against, so evidence and
        // plan can be reconciled without re-reading the file.
        #expect(evidence.sourceBeforeHash == point.sourceFileHash)
    }

    @Test("Writing in place leaves the mutated bytes on disk")
    func applyingInPlaceWritesTheFile() throws {
        let point = try discover(Self.source, path: "Sources/Cart.swift", using: Operators.boolLiteral)[0]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apply-\(UUID().uuidString).swift")
        try Data(Self.source.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let applied = try MutationApplication.applyInPlace(point, fileAt: url)
        let onDisk = try Data(contentsOf: url)

        #expect(onDisk == applied.mutatedSource)
        #expect(ContentHash.of(onDisk) == applied.evidence.sourceAfterHash)
    }

    // MARK: - Unicode

    /// Byte offsets and character offsets are not the same number, and a tool
    /// that mixes them up splices into the middle of a multi-byte scalar. The
    /// fixture puts CJK text and emoji ahead of every mutation site so the two
    /// offsets cannot coincide.
    @Test("Multi-byte characters before the site do not move the splice")
    func unicodeBeforeTheSiteDoesNotShiftTheSplice() throws {
        let source = try Fixture.text("UnicodeHeavy")
        let data = Data(source.utf8)
        let points = try discover(source, path: "Sources/UnicodeHeavy.swift")

        #expect(!points.isEmpty)

        for point in points {
            let applied = try MutationApplication.apply(point, to: data)
            let mutated = String(decoding: applied.mutatedSource, as: UTF8.self)

            // A splice at a character offset would land earlier than the byte
            // offset and shred a multi-byte scalar; the round trip through
            // UTF-8 decoding would then not be lossless.
            #expect(Array(mutated.utf8) == [UInt8](applied.mutatedSource))
            #expect(!mutated.unicodeScalars.contains("\u{FFFD}"), "the splice corrupted a multi-byte scalar")
            #expect(parsesWithoutError(applied.mutatedSource))

            // Every multi-byte run in the file is still intact.
            for preserved in ["🎌🍣🍜", "🍣 寿司セット", "特盛り！🍜🍱🎌", "日本語のコメント", "発送済み 📦"] {
                #expect(mutated.contains(preserved), "\(preserved) did not survive the splice")
            }
        }
    }

    /// Derives the expected offset from the raw bytes independently, and proves
    /// the two offsets genuinely disagree for this fixture — otherwise the test
    /// above would pass just as happily on a character-offset implementation.
    @Test("The anchor is a byte offset, not a character offset")
    func anchorsAreByteOffsets() throws {
        let source = try Fixture.text("UnicodeHeavy")
        let points = try discover(source, path: "Sources/UnicodeHeavy.swift", using: Operators.boolLiteral)

        let point = try #require(points.first { $0.originalText == "false" })
        let expectedByteOffset = try #require(utf8Offset(of: "false", in: source))
        #expect(point.utf8Range.start == expectedByteOffset)

        let characterOffset = source.distance(
            from: source.startIndex,
            to: try #require(source.range(of: "false")).lowerBound
        )
        #expect(
            characterOffset != expectedByteOffset,
            "the fixture must contain multi-byte characters before the first site"
        )
    }
}
