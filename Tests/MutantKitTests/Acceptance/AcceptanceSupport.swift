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

        return destination
    }

    /// A simulator destination this machine can actually satisfy.
    ///
    /// Discovered rather than pinned. A fixture naming `iPhone 17 Pro` only runs
    /// where that model exists, so it would fail on a CI runner with an older
    /// Xcode — and fail as an infrastructure error, which looks exactly like the
    /// tool being broken. Any iPhone exercises the same code path.
    ///
    /// The name is passed through, not the UDID: the point is to let the pool do
    /// the resolving, since that is the behaviour under test.
    static func iPhoneDestination() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "--json"]

        let pipe = cloexecPipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        struct Listing: Decodable {
            struct Device: Decodable {
                let name: String
                let isAvailable: Bool?
            }

            let devices: [String: [Device]]
        }

        let listing = try JSONDecoder().decode(Listing.self, from: data)
        // Sorted for determinism: two runs on one machine must choose the same
        // device, or a flake becomes impossible to reproduce.
        let iPhones = listing.devices
            .filter { $0.key.contains("iOS") }
            .flatMap(\.value)
            .filter { ($0.isAvailable ?? true) && $0.name.hasPrefix("iPhone") }
            .map(\.name)
            .sorted()

        guard let device = iPhones.first else {
            throw AcceptanceError.noSimulator
        }
        return "platform=iOS Simulator,name=\(device)"
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = try binary()
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let pipe = cloexecPipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Read before waiting: a full pipe blocks the child, and these commands
        // are verbose enough to fill one.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

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
    static func planAndRun(
        fixture: String,
        configuration: String? = nil,
        extraRunArguments: [String] = []
    ) throws -> AcceptanceRun {
        let directory = try stageFixture(fixture)

        if let configuration {
            try Data(configuration.utf8)
                .write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)
        }

        let plan = try run(["plan", "--output", "plan.json"], in: directory)
        guard plan.exitCode == 0 else {
            throw AcceptanceError.commandFailed(command: "plan", exitCode: plan.exitCode, output: plan.output)
        }

        let execution = try run(
            ["run", "--plan", "plan.json", "--report", "json"] + extraRunArguments,
            in: directory
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
