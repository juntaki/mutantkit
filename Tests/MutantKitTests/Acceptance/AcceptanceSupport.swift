@testable import AppleBuildAdapters
import Darwin
import Foundation
import MutationModel
import Testing

/// Drives the real `mutantkit` binary against a real fixture project.
///
/// These go through the executable rather than the library on purpose. The bugs
/// this layer exists to catch have all been wiring bugs, invisible to a test that
/// constructs the pieces itself: a sandbox handed source-file globs where it
/// wanted workspace excludes, an `xcodebuild` invocation pointed at the original
/// project while the mutated copy sat unread beside it. Both produced confident,
/// entirely wrong numbers, and both lived in the CLI.
///
/// Off by default. They build and test whole projects — tens of seconds for a
/// Swift package, minutes for anything through a simulator — which is too slow to
/// pay on every `swift test`. CI runs them; see `.github/workflows/ci.yml`.
///
///     MUTANTKIT_ACCEPTANCE=1 swift test
enum Acceptance {
    /// Enables the Swift-package suites. Fast enough for any machine.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MUTANTKIT_ACCEPTANCE"] == "1"
    }

    /// Additionally enables the suites that need an iOS simulator runtime.
    static var simulatorEnabled: Bool {
        isEnabled && ProcessInfo.processInfo.environment["MUTANTKIT_ACCEPTANCE_SIMULATOR"] != "0"
    }

    /// Derived from this file's location so the tests do not depend on the
    /// working directory `swift test` happens to be invoked from.
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/MutantKitTests/Acceptance/AcceptanceSupport.swift
            .deletingLastPathComponent() // Acceptance
            .deletingLastPathComponent() // MutantKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
    }

    /// `swift test` builds the package's executables too, so this exists whenever
    /// these tests run. A missing binary is a real failure, not a reason to skip:
    /// silently skipping is how an acceptance suite rots into decoration.
    static func binary() throws -> URL {
        let url = packageRoot.appendingPathComponent(".build/debug/mutantkit")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw AcceptanceError.binaryMissing(url.path)
        }
        return url
    }

    /// Root of a real, packaged `mutantkit` release install — produced by
    /// `scripts/release-build.sh` and extracted from its tarball, never the
    /// `swift build` debug binary `binary()` points at. Set only by the
    /// release-package E2E CI jobs (see `.github/workflows/ci.yml`); `nil`
    /// everywhere else, including an ordinary `MUTANTKIT_ACCEPTANCE=1` run
    /// — see `ReleaseBundledSchemataRuntimeAcceptanceTests`, the one suite
    /// that reads it.
    static var releasePackageRoot: URL? {
        guard let raw = ProcessInfo.processInfo.environment["MUTANTKIT_RELEASE_PACKAGE_ROOT"], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw)
    }

    /// The `mutantkit` executable inside `releasePackageRoot` — a missing
    /// binary here is a real failure for the same reason `binary()`'s own
    /// doc comment gives, once the suite has actually been enabled.
    static func releasePackageBinary() throws -> URL {
        guard let root = releasePackageRoot else {
            throw AcceptanceError.binaryMissing("MUTANTKIT_RELEASE_PACKAGE_ROOT is not set")
        }
        let url = root.appendingPathComponent("mutantkit")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw AcceptanceError.binaryMissing(url.path)
        }
        return url
    }

    /// Copies a fixture into a temporary directory.
    ///
    /// Never runs against `Fixtures/` in place: a run writes sandboxes, DerivedData
    /// and reports, and a test that dirties the repository is a test people learn
    /// to avoid running. A private copy also lets suites run concurrently.
    static func stageFixture(_ name: String) throws -> URL {
        let source = packageRoot.appendingPathComponent("Fixtures/\(name)")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AcceptanceError.fixtureMissing(source.path)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-acceptance-\(name)-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: destination)

        // A fixture may carry build output from a developer's local run. Copying
        // it would poison the sandbox exactly as it did in production: SwiftPM
        // records absolute paths in `.build`, so a copy of it at a new path fails
        // before it compiles anything.
        for stale in [".build", ".mutantkit", "DerivedData", "dd"] {
            try? FileManager.default.removeItem(at: destination.appendingPathComponent(stale))
        }

        try retargetPinnedSimulator(inFixtureAt: destination)
        return destination
    }

    /// Configuration for the generated macOS-only framework projects. Their
    /// schemes have no iOS destination, so the iOS Simulator default every other
    /// Xcode configuration falls back to would fail with "unable to find a
    /// destination" on any machine, whatever runtimes it has.
    static func macOSConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.project.destination = "platform=macOS"
        return configuration
    }

    /// A fixture's own `mutantkit.yml` pins a simulator model for readers. That
    /// model exists only under some runtimes, so a machine with several
    /// installed runtimes can legitimately refuse it (`doctor` refuses to run
    /// against a different runtime than the one it resolves). The staged copy
    /// gets a destination this machine can satisfy instead; the checked-in
    /// fixture is untouched, and a machine without any simulator keeps the pin.
    private static func retargetPinnedSimulator(inFixtureAt directory: URL) throws {
        let configurationURL = directory.appendingPathComponent("mutantkit.yml")
        guard let text = try? String(contentsOf: configurationURL, encoding: .utf8),
              text.contains("destination: platform=iOS Simulator,"),
              let resolved = try? iPhoneDestination()
        else { return }

        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("destination: platform=iOS Simulator,") else { return line }
            let indent = line.prefix { $0 == " " }
            return "\(indent)destination: \(resolved)"
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: configurationURL, options: .atomic)
    }

    /// A suggested iOS Simulator destination: `name=iPhone…`, or the documented
    /// `id=<UDID>` form the detector emits when the same name exists under two
    /// runtimes of one version (see `XcodeConfigDetector.selectDestination`).
    static func isDetectedIOSSimulatorDestination(_ destination: String) -> Bool {
        destination.hasPrefix("platform=iOS Simulator,name=iPhone") || hasNonEmptyUDID(destination, after: "platform=iOS Simulator,id=")
    }

    /// `destination` starts with `prefix` and a non-empty UDID follows it.
    private static func hasNonEmptyUDID(_ destination: String, after prefix: String) -> Bool {
        guard destination.hasPrefix(prefix) else { return false }
        guard let first = destination.dropFirst(prefix.count).first else { return false }
        return first != "," && !first.isWhitespace
    }

    /// Whether `text` contains `prefix` followed by a detected iOS Simulator destination.
    static func containsDetectedDestination(_ prefix: String, in text: String) -> Bool {
        if text.contains(prefix + "platform=iOS Simulator,name=iPhone") { return true }
        let marker = prefix + "platform=iOS Simulator,id="
        var searchFrom = text.startIndex
        while let range = text.range(of: marker, range: searchFrom ..< text.endIndex) {
            if let first = text[range.upperBound...].first, first != ",", !first.isWhitespace, first != "\n" { return true }
            searchFrom = range.upperBound
        }
        return false
    }

    /// A simulator destination this machine can actually satisfy.
    ///
    /// Discovered rather than pinned. A fixture naming `iPhone 17 Pro` only runs
    /// where that model exists, so it would fail on a CI runner with an older
    /// Xcode — and fail as an infrastructure error, which looks exactly like the
    /// tool being broken. Any iPhone exercises the same code path.
    static func iPhoneDestination() throws -> String {
        try iPhoneDestination(
            runtimesJSON: simctlJSON(SimulatorRuntimeCatalog.runtimesArguments),
            devicesJSON: simctlJSON(SimulatorRuntimeCatalog.devicesArguments)
        )
    }

    /// The pure selection behind `iPhoneDestination()`, over the two `simctl` payloads.
    ///
    /// Built from `SimulatorRuntimeCatalog`: the OS version and platform come from
    /// each runtime's own `version`/`platform` fields, never from its identifier
    /// (`iOS-27-2-iPhone19-4` is OS 27.2). Scoped to the **latest iOS version that
    /// has an available iPhone** — a runner may ship several runtimes side by
    /// side, and a device provisioned only under an older one would collide with
    /// `xcodebuild`'s "no OS means latest" resolution. When several runtimes share
    /// that version, the first iPhone by name under the smallest runtime
    /// identifier is taken. The result addresses it by UDID (`id=`): internal to
    /// the acceptance suites, and unambiguous however many runtimes share the version.
    static func iPhoneDestination(runtimesJSON: Data, devicesJSON: Data) throws -> String {
        let catalog = try SimulatorRuntimeCatalog.build(runtimesJSON: runtimesJSON, devicesJSON: devicesJSON)
        let candidates = catalog.runtimes.filter { $0.platform == "iOS" && $0.devices.contains { $0.name.hasPrefix("iPhone") } }
        guard let latest = candidates.map(\.version).max() else { throw AcceptanceError.noSimulator }
        let runtimes = candidates.filter { $0.version == latest }
        let names = Set(runtimes.flatMap(\.devices).map(\.name).filter { $0.hasPrefix("iPhone") })
        guard let name = names.sorted().first, let device = SimulatorRuntimeCatalog.device(named: name, in: runtimes) else {
            throw AcceptanceError.noSimulator
        }
        return device.destination
    }

    /// Seconds a `simctl list` probe may take, read and exit together.
    private static let simctlProbeTimeoutSeconds = 30.0

    /// Runs `xcrun <arguments>` and returns its stdout, with the *whole* run bounded.
    ///
    /// Output goes to a file, not a pipe: reading a pipe to EOF blocks until the
    /// child closes it, which a stalled `simctl` never does, so the timeout would
    /// never start. Waiting is bounded by `BoundedProcessWait`, which kills a
    /// stuck process; the file is read only after it is gone.
    private static func simctlJSON(_ arguments: [String]) throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("simctl-probe-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard BoundedProcessWait.wait(process, timeoutSeconds: simctlProbeTimeoutSeconds) else {
            throw AcceptanceError.commandFailed(
                command: "xcrun \(arguments.joined(separator: " "))", exitCode: -1,
                output: "timed out after \(Int(simctlProbeTimeoutSeconds))s"
            )
        }
        guard process.terminationStatus == 0 else {
            throw AcceptanceError.commandFailed(
                command: "xcrun \(arguments.joined(separator: " "))", exitCode: process.terminationStatus,
                output: "simctl exited non-zero"
            )
        }
        return try Data(contentsOf: output)
    }

    /// - Parameter binary: which `mutantkit` executable to run — defaults to the
    ///   `swift build` debug binary. `ReleaseBundledSchemataRuntimeAcceptanceTests`
    ///   passes `releasePackageBinary()` instead, to drive a real packaged release
    ///   install rather than this checkout's own debug build.
    @discardableResult
    static func run(_ arguments: [String], in directory: URL, binary: URL? = nil) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = try binary ?? Acceptance.binary()
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let pipe = cloexecPipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Read before waiting: a full pipe blocks the child, and these commands
        // are verbose enough to fill one.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard BoundedProcessWait.wait(process) else {
            throw AcceptanceError.commandFailed(
                command: arguments.joined(separator: " "),
                exitCode: -1,
                output: "timed out and was force-killed: \(String(decoding: data, as: UTF8.self))"
            )
        }

        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A `Pipe()` with both ends marked close-on-exec immediately.
    ///
    /// `pipe(2)` does not set `FD_CLOEXEC` by default, so any *other*,
    /// unrelated `posix_spawn`/`Process.run()` call racing on another
    /// thread while this pipe's write end is still open can inherit a copy
    /// of it, holding it open long after the intended child has exited and
    /// blocking `readDataToEndOfFile()` forever — the identical bug class
    /// already fixed in `Sources/MutationExecution/ProcessSupervisor.swift`/
    /// `Sources/BenchmarkRunner/ToolRunner.swift`, caught here too by a real
    /// CI stack sample stuck in exactly this shape inside
    /// `ProcessSupervisorResidueTests.survivingProcesses(referencing:)`.
    /// Safe for the intended child's own stdout/stderr the same way it is
    /// there: POSIX `dup2` always clears close-on-exec on the *new*
    /// descriptor it creates, regardless of the source's own flag, so
    /// `Process.run()`'s own `dup2`-based wiring into the child's real fds
    /// 1/2 is unaffected by marking these *original* pipe fds here.
    private static func cloexecPipe() -> Pipe {
        let pipe = Pipe()
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            let flags = fcntl(handle.fileDescriptor, F_GETFD)
            _ = fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC)
        }
        return pipe
    }

    /// Plans and runs a fixture, returning the parsed report.
    ///
    /// - Parameter binary: forwarded to `run(_:in:binary:)` — see its own doc comment.
    static func planAndRun(
        fixture: String,
        configuration: String? = nil,
        extraRunArguments: [String] = [],
        binary: URL? = nil
    ) throws -> AcceptanceRun {
        let directory = try stageFixture(fixture)

        if let configuration {
            try Data(configuration.utf8)
                .write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)
        }

        let plan = try run(["plan", "--output", "plan.json"], in: directory, binary: binary)
        guard plan.exitCode == 0 else {
            throw AcceptanceError.commandFailed(command: "plan", exitCode: plan.exitCode, output: plan.output)
        }

        let execution = try run(
            ["run", "--plan", "plan.json", "--report", "json"] + extraRunArguments,
            in: directory, binary: binary
        )

        let reportURL = directory.appendingPathComponent(".mutantkit/report.json")
        guard let data = try? Data(contentsOf: reportURL) else {
            throw AcceptanceError.commandFailed(
                command: "run", exitCode: execution.exitCode, output: execution.output
            )
        }

        return AcceptanceRun(
            report: try MutationPlan.decoder().decode(RunReport.self, from: data),
            planOutput: plan.output,
            runOutput: execution.output,
            exitCode: execution.exitCode,
            directory: directory
        )
    }
}

struct AcceptanceRun {
    let report: RunReport
    let planOutput: String
    let runOutput: String
    let exitCode: Int32
    let directory: URL

    /// A mutation identified the way a human describes one, so an assertion names
    /// the mutation rather than an opaque hash.
    struct Mutation: Hashable, CustomStringConvertible {
        let declaration: String
        let original: String
        let replacement: String

        var description: String { "\(declaration): \(original) → \(replacement)" }
    }

    func mutations(withOutcome outcome: MutationOutcome) -> Set<Mutation> {
        Set(
            report.results
                .filter { $0.outcome == outcome }
                .map {
                    Mutation(
                        declaration: $0.point.enclosingDeclaration.path.last ?? "?",
                        original: $0.point.originalText,
                        replacement: $0.point.replacementText
                    )
                }
        )
    }

    var killed: Set<Mutation> {
        mutations(withOutcome: .killedByAssertion).union(mutations(withOutcome: .killedByCrash))
    }

    /// Every fact a "zero fallback" expectation needs in order to be
    /// actionable from a CI log alone: which reasons the fallbacks were
    /// attributed to, and — the part that actually names a cause — each
    /// operational issue's own diagnosis, which for a failed chunk build
    /// carries `BuildClassifier`'s first compiler diagnostic.
    ///
    /// Attached to those expectations because their failure message
    /// otherwise reports only that a count was not zero. A real CI failure
    /// (`sharedChunkBuildFailure: 1` of 6 chunks, recurring on `main`) was
    /// undiagnosable from its artifacts for exactly that reason: the
    /// diagnosis existed, in the report and on stderr, and nothing the job
    /// uploaded ever showed it.
    var schemataFallbackEvidence: String {
        let strategy = report.executionStrategy
        let issues = report.operationalIssues.map { "  [\($0.severity.rawValue)] \($0.kind.rawValue): \($0.diagnosis)" }
        return """
        degradationReason: \(strategy?.degradationReason ?? "nil")
        effective/fallback: \(strategy?.effectiveCount ?? -1)/\(strategy?.fallbackCount ?? -1) of \(report.integrity.planned) planned
        fallbackReasonCounts: \(strategy?.fallbackReasonCounts ?? [:])
        plannerFallbackReasonCounts: \(strategy?.plannerFallbackReasonCounts ?? [:])
        operationalIssues:
        \(issues.isEmpty ? "  (none)" : issues.joined(separator: "\n"))
        console:
        \(consoleEvidence)
        """
    }

    /// The lines of the plan and run console output that explain how the
    /// schemata backend was used: the `!` warning lines (for instance the one
    /// printed when target resolution or chunk planning fails and the run
    /// degrades) and every line that mentions schemata. A whole-run
    /// degradation can be absent from the report's own fields, so without
    /// these the failure message cannot say why the backend degraded.
    var consoleEvidence: String {
        let lines = (planOutput + "\n" + runOutput).split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("!") || $0.localizedCaseInsensitiveContains("schemata") }
        return lines.isEmpty ? "  (no warning or schemata lines in the console output)" : lines.map { "  \($0)" }.joined(separator: "\n")
    }

    /// The same idea for the other way this bar fails: a baseline that did
    /// not pass. `BaselineRecord` carries the commands and durations that
    /// separate "the project did not build" from "the suite ran and was
    /// red" from "nothing ran at all", none of which a bare
    /// `#expect(baseline.passed)` failure prints.
    var baselineEvidence: String {
        "baseline: \(report.baseline)\ndegradationReason: \(report.executionStrategy?.degradationReason ?? "nil")\nconsole:\n\(consoleEvidence)"
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum AcceptanceError: Error, CustomStringConvertible {
    case binaryMissing(String)
    case fixtureMissing(String)
    case noSimulator
    case commandFailed(command: String, exitCode: Int32, output: String)

    var description: String {
        switch self {
        case let .binaryMissing(path):
            "The mutantkit binary is not at \(path). Run `swift build` first."
        case let .fixtureMissing(path):
            "No fixture at \(path)."
        case .noSimulator:
            "No iPhone simulator is available. Install a runtime in Xcode > Settings > Components."
        case let .commandFailed(command, exitCode, output):
            "`mutantkit \(command)` exited \(exitCode):\n\(output)"
        }
    }
}
