import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// The diff is the artifact a reviewer actually reads to decide whether a
/// surviving mutant matters, and the evidence that the mutation reached the
/// source at all. A diff that is merely plausible is worse than none.
@Suite("Source diff")
struct SourceDiffTests {
    /// Splits the diff into its lines, dropping the trailing empty element the
    /// final newline produces.
    private func lines(_ diff: String) -> [String] {
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private func diff(for source: String, path: String = "Sources/Feature.swift") throws -> (String, MutationPoint) {
        let point = try discover(source, path: path, using: Operators.boolLiteral)[0]
        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        return (applied.evidence.sourceDiff, point)
    }

    @Test("A single-line change produces one hunk with one removal and one addition")
    func singleLineChangeIsOneHunk() throws {
        let source = """
        struct Feature {
            let a = 1
            let b = 2
            let c = 3
            let d = 4
            let enabled = true
            let e = 5
            let f = 6
            let g = 7
        }
        """

        let (diff, _) = try diff(for: source)
        let lines = lines(diff)

        #expect(lines[0] == "--- a/Sources/Feature.swift")
        #expect(lines[1] == "+++ b/Sources/Feature.swift")

        // Exactly one hunk.
        #expect(lines.filter { $0.hasPrefix("@@") }.count == 1)

        let removals = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }
        let additions = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
        #expect(removals == ["-    let enabled = true"])
        #expect(additions == ["+    let enabled = false"])
    }

    /// The change sits on line 6 with three lines of context, so the hunk starts
    /// at line 3 and spans 3 context + 1 changed + 3 context = 7 lines on each
    /// side. A wrong `@@` sends a reviewer to the wrong place in the file.
    @Test("The hunk header carries the right line numbers and counts")
    func hunkHeaderIsCorrect() throws {
        let source = """
        struct Feature {
            let a = 1
            let b = 2
            let c = 3
            let d = 4
            let enabled = true
            let e = 5
            let f = 6
            let g = 7
        }
        """

        let (diff, point) = try diff(for: source)

        #expect(point.line == 6, "the fixture must put the mutation on line 6")
        #expect(lines(diff)[2] == "@@ -3,7 +3,7 @@")
    }

    @Test("Context lines are the real neighbouring lines")
    func contextIsAccurate() throws {
        let source = """
        struct Feature {
            let a = 1
            let b = 2
            let c = 3
            let d = 4
            let enabled = true
            let e = 5
            let f = 6
            let g = 7
        }
        """

        let (diff, _) = try diff(for: source)

        #expect(lines(diff) == [
            "--- a/Sources/Feature.swift",
            "+++ b/Sources/Feature.swift",
            "@@ -3,7 +3,7 @@",
            "     let b = 2",
            "     let c = 3",
            "     let d = 4",
            "-    let enabled = true",
            "+    let enabled = false",
            "     let e = 5",
            "     let f = 6",
            "     let g = 7"
        ])
    }

    /// Boundary: there is nothing above the change to use as context, and
    /// expanding backwards must stop at the start of the file rather than
    /// producing a negative offset or a line 0.
    @Test("A change on the first line produces a diff with no leading context")
    func changeOnFirstLine() throws {
        let source = """
        let enabled = true
        let a = 1
        let b = 2
        let c = 3
        """

        let (diff, point) = try diff(for: source, path: "Sources/First.swift")

        #expect(point.line == 1)
        #expect(lines(diff) == [
            "--- a/Sources/First.swift",
            "+++ b/Sources/First.swift",
            "@@ -1,4 +1,4 @@",
            "-let enabled = true",
            "+let enabled = false",
            " let a = 1",
            " let b = 2",
            " let c = 3"
        ])
    }

    /// Boundary: expanding forwards must stop at the end of the file. This
    /// fixture also has no trailing newline, the case where an off-by-one in the
    /// line scan shows up.
    @Test("A change on the last line produces a diff with no trailing context")
    func changeOnLastLine() throws {
        let source = """
        let a = 1
        let b = 2
        let c = 3
        let enabled = true
        """

        let (diff, point) = try diff(for: source, path: "Sources/Last.swift")

        #expect(point.line == 4)
        #expect(lines(diff) == [
            "--- a/Sources/Last.swift",
            "+++ b/Sources/Last.swift",
            "@@ -1,4 +1,4 @@",
            " let a = 1",
            " let b = 2",
            " let c = 3",
            "-let enabled = true",
            "+let enabled = false"
        ])
    }

    @Test("A change on the only line of a file produces a diff with no context at all")
    func changeOnTheOnlyLine() throws {
        let (diff, _) = try diff(for: "let enabled = true", path: "Sources/Only.swift")

        #expect(lines(diff) == [
            "--- a/Sources/Only.swift",
            "+++ b/Sources/Only.swift",
            "@@ -1,1 +1,1 @@",
            "-let enabled = true",
            "+let enabled = false"
        ])
    }

    @Test("The removed line is the source and the added line is the mutant")
    func diffReflectsTheActualSplice() throws {
        let source = try Fixture.text("RealisticViewModel")
        let data = Data(source.utf8)

        for point in try discover(source, path: "Sources/CartViewModel.swift") {
            let applied = try MutationApplication.apply(point, to: data)
            let lines = lines(applied.evidence.sourceDiff)

            let removals = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }
            let additions = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }

            // Every mutation in this fixture is confined to one line, so the
            // splice must show up as exactly one line replaced by one line.
            #expect(removals.count == 1, "\(point.displayLocation) produced \(removals.count) removals")
            #expect(additions.count == 1)
            #expect(removals[0].dropFirst().contains(point.originalText))
            #expect(additions[0].dropFirst().contains(point.replacementText))
        }
    }

    @Test("A range beyond the end of the file yields no diff rather than a wrong one")
    func outOfBoundsRangeProducesNoDiff() {
        let before = Data("let a = 1\n".utf8)

        let diff = SourceDiff.unified(
            before: before,
            after: before,
            changedRange: ByteRange(start: 100, end: 104),
            path: "Sources/Example.swift"
        )

        #expect(diff.isEmpty)
    }
}
