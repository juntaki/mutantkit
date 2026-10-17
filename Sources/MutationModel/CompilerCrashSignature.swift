import Foundation

/// What identifies one compiler crash, taken from the compiler's own crash output, so that a second
/// crash can be told apart from the first.
///
/// An independent rebuild of a mutant that crashes the compiler again only confirms the crash when it
/// is the *same* crash: the same signal, the same thing the compiler was processing, and the same
/// compiler frames at the top of the stack. Two crashes at different places point to an unstable
/// machine, not to the mutated source, and stay infrastructure failures.
///
/// Everything that varies between runs of the same crash is normalised away: addresses, offsets inside
/// a function, and the directory a source file was in (each rebuild uses its own sandbox).
public struct CompilerCrashSignature: Equatable, Sendable {
    /// The signal the crash banner names (`Segmentation fault`, `Illegal instruction`, `Abort trap`,
    /// `Bus error`), or `signal handler` when only the signal-handler frame shows that one was delivered.
    public let signal: String
    /// The compiler's `While ...` lines (what it was evaluating or type-checking), paths reduced to file
    /// names.
    public let context: [String]
    /// The first compiler frames after the stack-trace printer and signal handler, as bare symbol names.
    public let frames: [String]

    /// How many compiler frames take part in the comparison.
    static let frameCount = 3

    private static let signals = ["Segmentation fault", "Illegal instruction", "Abort trap", "Bus error"]
    private static let noiseFrames = ["PrintStackTrace", "SignalHandler", "RunSignalHandlers", "sigtramp", "llvm::sys::"]
    private static let compilerImages = ["swift-frontend", "swift-driver"]

    // The patterns are literals checked by the tests that exercise this type.
    private static let frameLine = regex(#"^\s*\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.+?)(?:\s+\+\s+\d+)?\s*$"#)
    private static let contextLine = regex(#"^\s*\d+\.\s+(While .+?)\s*$"#)
    private static let directoryPrefix = regex(#"(?:/[^/\s"')]+)+/([^/\s"')]+)"#)
    private static let address = regex(#"0x[0-9a-fA-F]+"#)

    /// The signature of the crash in `output`, or `nil` when the output does not carry enough to tell
    /// this crash from another (no compiler frame and no `While` line). Such a crash can be a candidate
    /// but never confirmed.
    public init?(output: String) {
        var contexts: [String] = []
        var frames: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if let context = Self.capture(Self.contextLine, in: line) {
                contexts.append(Self.normalised(context))
            } else if let frame = Self.compilerFrame(in: line), frames.count < Self.frameCount {
                frames.append(frame)
            }
        }
        guard !contexts.isEmpty || !frames.isEmpty else { return nil }
        signal = Self.signalName(in: output)
        context = contexts
        self.frames = frames
    }

    /// The signal named earliest in the output: the crash banner comes before anything the compiler prints
    /// about it afterwards.
    private static func signalName(in output: String) -> String {
        var earliest: (name: String, offset: Int)?
        for name in signals {
            guard let found = output.range(of: name) else { continue }
            let offset = output.distance(from: output.startIndex, to: found.lowerBound)
            if let current = earliest, current.offset <= offset { continue }
            earliest = (name, offset)
        }
        return earliest?.name ?? "signal handler"
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            fatalError("invalid regular expression \(pattern): \(error)")
        }
    }

    private static func capture(_ expression: NSRegularExpression, in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range), match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[group])
    }

    /// The symbol of a stack-trace line that belongs to the compiler and is not part of printing the
    /// trace or handling the signal; `nil` for every other line.
    private static func compilerFrame(in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = frameLine.firstMatch(in: line, range: range), match.numberOfRanges > 2,
              let image = Range(match.range(at: 1), in: line), let symbol = Range(match.range(at: 2), in: line)
        else { return nil }
        guard compilerImages.contains(where: { line[image].hasPrefix($0) }) else { return nil }
        let name = String(line[symbol])
        return noiseFrames.contains(where: name.contains) ? nil : name
    }

    private static func normalised(_ text: String) -> String {
        var result = text
        for (expression, template) in [(directoryPrefix, "$1"), (address, "0x")] {
            result = expression.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template
            )
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
