import Foundation

// TEMP diagnostic tool for the "direct test-binary invocation" prototype
// (Research: does bypassing `xcrun swift test`'s own CLI/package-graph
// layer, and invoking the already-built .xctest bundle straight through
// `xcrun xctest -XCTest <Class>/<method> <bundle>`, actually save wall
// time for a single-test SwiftPM/macOS run?). Standalone — no dependency
// on any MutantKit module, since this doesn't test MutantKit's own
// runner, it measures a mechanism against an arbitrary already-built
// SwiftPM package. Not part of any frozen protocol; not intended to be a
// long-lived target, and NOT wired into AppleBuildAdapters/MutationRunner
// — that integration is a later step, after this prototype's numbers are
// in.
//
// Usage:
//   DirectXCTestInvokeProbe <projectRoot> <repeats> <Class/method> [<Class/method> ...]
//
// For each given "Class/method" test identifier, runs `repeats` timed
// trials of:
//   (a) the traditional path:  xcrun swift test --skip-build --filter <id>
//   (b) the direct path:       xcrun xctest -XCTest <id> <bundle>
// against the SAME already-built package (this tool never builds
// anything itself — run `swift build --build-tests` in <projectRoot>
// first), and prints per-test averages plus an overall summary.
//
// Exit code 0 on success, 2 on usage/setup error, 1 if any trial's pass/
// fail outcome disagreed between the two paths (that would mean this
// "prototype" isn't actually measuring the same thing).

setvbuf(stdout, nil, _IONBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    fail("""
    usage: DirectXCTestInvokeProbe <projectRoot> <repeats> <Class/method> [<Class/method> ...]
    example: DirectXCTestInvokeProbe /path/to/swift-numerics 3 \
      IntegerUtilitiesGCDTests/testGCDInt IntegerUtilitiesRotateTests/testRotateUInt8
    """)
}

let projectRoot = URL(fileURLWithPath: args[1]).standardizedFileURL
guard let repeats = Int(args[2]), repeats >= 1 else {
    fail("repeats must be a positive integer, got \(args[2])")
}

let testIDs = Array(args[3...])

// MARK: - Process helpers

struct RunResult {
    let exitCode: Int32
    let output: String
    let wallSeconds: Double
}

@discardableResult
func run(
    _ executable: String,
    _ arguments: [String],
    cwd: URL,
    captureOutput: Bool = false
) throws -> RunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd

    let pipe = Pipe()
    if captureOutput {
        process.standardOutput = pipe
        process.standardError = pipe
    } else {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    let clock = ContinuousClock()
    let start = clock.now
    try process.run()

    var collected = Data()
    if captureOutput {
        // Read incrementally so a chatty child can't deadlock on a full pipe.
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            collected.append(chunk)
        }
    }
    process.waitUntilExit()
    let elapsed = start.duration(to: clock.now)
    let seconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18

    return RunResult(
        exitCode: process.terminationStatus,
        output: String(data: collected, encoding: .utf8) ?? "",
        wallSeconds: seconds
    )
}

// MARK: - Step 1: locate the built .xctest bundle via SwiftPM itself

print("=== Resolving bin path (swift build --show-bin-path) ===")
let binPathResult = try run(
    "/usr/bin/xcrun",
    ["swift", "build", "--show-bin-path"],
    cwd: projectRoot,
    captureOutput: true
)
guard binPathResult.exitCode == 0 else {
    fail("`swift build --show-bin-path` failed:\n\(binPathResult.output)")
}

let binPath = binPathResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
print("  bin path: \(binPath)")

let binURL = URL(fileURLWithPath: binPath)
let entries = (try? FileManager.default.contentsOfDirectory(
    at: binURL, includingPropertiesForKeys: nil
)) ?? []
let xctestBundles = entries.filter { $0.pathExtension == "xctest" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !xctestBundles.isEmpty else {
    fail("""
    No .xctest bundle found under \(binPath).
    Run `swift build --build-tests` in \(projectRoot.path) first.
    """)
}

// SwiftPM/macOS merges every test target in the package into ONE
// `<PackageName>PackageTests.xctest` bundle (empirically confirmed against
// this repo and swift-numerics) — there is exactly one bundle to pick in
// the overwhelmingly common case, but fail loudly instead of silently
// guessing if that ever isn't true.
if xctestBundles.count > 1 {
    print("  WARNING: multiple .xctest bundles found, using the first: \(xctestBundles.map(\.lastPathComponent))")
}

let bundleURL = xctestBundles[0]
let bundleExecutable = bundleURL
    .appendingPathComponent("Contents/MacOS")
    .appendingPathComponent(bundleURL.deletingPathExtension().lastPathComponent)
guard FileManager.default.fileExists(atPath: bundleExecutable.path) else {
    fail("Expected Mach-O executable not found at \(bundleExecutable.path)")
}

print("  xctest bundle: \(bundleURL.path)")
print("")

// MARK: - Step 2: time both paths for each test ID

struct Trial {
    let seconds: Double
    let exitCode: Int32
    let passed: Bool
}

struct TimingSummary {
    let avg: Double
    let min: Double
    let max: Double
}

func summarize(_ trials: [Trial]) -> TimingSummary {
    let seconds = trials.map(\.seconds)
    let avg = seconds.reduce(0, +) / Double(seconds.count)
    return TimingSummary(avg: avg, min: seconds.min() ?? 0, max: seconds.max() ?? 0)
}

// "passed" is inferred from swift-corelibs-xctest / Apple XCTest's
// well-known summary line, present on both the `swift test` and the raw
// `xctest` output paths, so the same check works for both.
func inferredPass(_ output: String, exitCode: Int32) -> Bool {
    exitCode == 0 && output.contains("with 0 failures")
}

var allTraditional: [Trial] = []
var allDirect: [Trial] = []
var anyMismatch = false

print("=== Timing \(testIDs.count) test(s), \(repeats) repeat(s) each ===")
for testID in testIDs {
    var traditionalTrials: [Trial] = []
    var directTrials: [Trial] = []

    for _ in 0 ..< repeats {
        let r = try run(
            "/usr/bin/xcrun",
            ["swift", "test", "--skip-build", "--filter", testID],
            cwd: projectRoot,
            captureOutput: true
        )
        traditionalTrials.append(Trial(seconds: r.wallSeconds, exitCode: r.exitCode, passed: inferredPass(r.output, exitCode: r.exitCode)))
    }

    for _ in 0 ..< repeats {
        let r = try run(
            "/usr/bin/xcrun",
            ["xctest", "-XCTest", testID, bundleURL.path],
            cwd: projectRoot,
            captureOutput: true
        )
        directTrials.append(Trial(seconds: r.wallSeconds, exitCode: r.exitCode, passed: inferredPass(r.output, exitCode: r.exitCode)))
    }

    let tSummary = summarize(traditionalTrials)
    let dSummary = summarize(directTrials)
    let tPassed = traditionalTrials.allSatisfy(\.passed)
    let dPassed = directTrials.allSatisfy(\.passed)
    if tPassed != dPassed {
        anyMismatch = true
        print("  MISMATCH on \(testID): traditional passed=\(tPassed), direct passed=\(dPassed)")
    }

    let speedup = tSummary.avg / max(dSummary.avg, 0.0001)
    let paddedID = testID.padding(toLength: max(testID.count, 55), withPad: " ", startingAt: 0)
    print(String(
        format: "  %@ traditional avg=%.3fs (min=%.3f max=%.3f)  direct avg=%.3fs (min=%.3f max=%.3f)  speedup=%.1fx  pass(t/d)=%@/%@",
        paddedID as NSString, tSummary.avg, tSummary.min, tSummary.max,
        dSummary.avg, dSummary.min, dSummary.max, speedup,
        tPassed ? "Y" as NSString : "N" as NSString,
        dPassed ? "Y" as NSString : "N" as NSString
    ))

    allTraditional.append(contentsOf: traditionalTrials)
    allDirect.append(contentsOf: directTrials)
}

print("")
print("=== Overall ===")
let overallT = summarize(allTraditional)
let overallD = summarize(allDirect)
print(String(format: "  traditional (swift test --skip-build --filter): avg=%.3fs across %d trials", overallT.avg, allTraditional.count))
print(String(format: "  direct      (xcrun xctest -XCTest ... bundle):  avg=%.3fs across %d trials", overallD.avg, allDirect.count))
print(String(format: "  overall speedup: %.1fx", overallT.avg / max(overallD.avg, 0.0001)))

if anyMismatch {
    print("\nFAIL: at least one test's pass/fail outcome disagreed between the two invocation paths.")
    exit(1)
}
