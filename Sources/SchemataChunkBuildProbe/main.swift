import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend

// TEMP diagnostic tool. Build-only reproducer for delta-debugging a
// schemata chunk compile failure — never runs tests. Two subcommands:
//
//   schemata <plan.json> <projectRoot> <scratchRoot> [--ids-file <path>] [--keep]
//     Restricts the plan to the MutationIDs in --ids-file (or the whole
//     plan if omitted), plans schemata chunks for exactly that set, and
//     runs SchemataBuildable.buildSchemataChunk for each resulting
//     program — the same call the real runner makes, minus every test
//     invocation after it.
//
//   isolated <plan.json> <projectRoot> <scratchRoot> --mutation-id <id> [--keep]
//     Applies exactly one mutation in place in a fresh sandbox and runs
//     BuildAdapter.buildMutant — the isolated-mode build path, for
//     comparison against a mutation's schemata-mode build outcome.
//
// Exit code 0 = build succeeded, 1 = build failed, 2 = usage/setup error.
// --keep leaves the sandbox on disk (path printed) instead of destroying
// it, so a failing reproducer can be inspected or handed to Codex review.

setvbuf(stdout, nil, _IONBF, 0)

func fail(_ message: String) -> Never {
    print("error: \(message)")
    exit(2)
}

func flagValue(_ name: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else {
    fail("usage: SchemataChunkBuildProbe <schemata|isolated> <plan.json> <projectRoot> <scratchRoot> [options]")
}
let mode = args[0]
let planPath = args[1]
let projectRoot = URL(fileURLWithPath: args[2])
let scratchRoot = URL(fileURLWithPath: args[3])
let keep = args.contains("--keep")

let planData = try Data(contentsOf: URL(fileURLWithPath: planPath))
let fullPlan = try MutationPlan.decode(from: planData)

let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)
let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())

func printFailure(_ error: Error) {
    if let failure = error as? BuildFailure {
        print("BUILD FAILED (\(failure.kind))")
        print("diagnosis: \(failure.diagnosis)")
        print("--- output (last 4000 chars) ---")
        print(String(failure.output.suffix(4000)))
    } else {
        print("BUILD FAILED (non-BuildFailure error)")
        print("\(error)")
    }
}

switch mode {
case "schemata":
    var ids: Set<MutationID>?
    if let idsFile = flagValue("--ids-file", in: args) {
        let idsData = try Data(contentsOf: URL(fileURLWithPath: idsFile))
        let rawIDs = try JSONDecoder().decode([String].self, from: idsData)
        ids = Set(rawIDs.map(MutationID.init(rawValue:)))
    }

    let scopedMutations = ids.map { idSet in fullPlan.mutations.filter { idSet.contains($0.id) } } ?? fullPlan.mutations
    guard !scopedMutations.isEmpty else { fail("no mutations matched --ids-file") }
    print("scoped mutation count: \(scopedMutations.count)")
    print("scoped mutation IDs: \(scopedMutations.map(\.id.rawValue).sorted())")

    let plan = MutationPlan(
        planID: fullPlan.planID, createdAt: fullPlan.createdAt, projectRoot: fullPlan.projectRoot,
        toolchain: fullPlan.toolchain, configurationHash: fullPlan.configurationHash,
        sourceFileHashes: fullPlan.sourceFileHashes, mutations: scopedMutations, skipped: fullPlan.skipped,
        operators: fullPlan.operators
    )

    var sources: [String: Data] = [:]
    for file in Set(plan.mutations.map(\.file)) {
        sources[file] = try Data(contentsOf: projectRoot.appendingPathComponent(file))
    }
    let targetInfo = try await SwiftPMTargetResolver.resolveTargetInfo(projectRoot: projectRoot)
    let targetFiles = Set(targetInfo.keys).subtracting(sources.keys)
    for file in targetFiles {
        sources[file] = try Data(contentsOf: projectRoot.appendingPathComponent(file))
    }

    let registry = try SchemataLowererRegistry()
    let backend = SchemataBackendInfo(
        backendID: "chunk-build-probe", backendVersion: 1,
        toolchainHash: "n/a", buildArgumentsHash: plan.configurationHash
    )
    let planResult = try SchemataChunkPlanner.plan(
        mutationPlan: plan, registry: registry, sources: sources, targetInfo: targetInfo, backend: backend
    )

    print("programs produced: \(planResult.programs.count)")
    let embeddedCount = planResult.schemataPlan.entries.count(where: \.isEmbedded)
    let fallbackCount = planResult.schemataPlan.entries.count - embeddedCount
    print("planner-embedded: \(embeddedCount), planner-fallback: \(fallbackCount)")
    if fallbackCount > 0 {
        let reasons = planResult.schemataPlan.entries.filter { !$0.isEmbedded }.map { "\($0.mutationID.rawValue): \(String(describing: $0.fallbackReason))" }
        print("fallback entries (not build-probed, planner routed them to isolated already):")
        reasons.forEach { print("  \($0)") }
    }

    guard !planResult.programs.isEmpty else {
        print("no embeddable program produced for this subset — nothing to build-probe")
        exit(0)
    }

    var anyFailed = false
    for program in planResult.programs {
        print("\n=== program chunkID=\(program.chunkID) entries=\(program.entries.count) ===")
        print("member mutationIDs: \(program.entries.map(\.mutationID.rawValue).sorted())")
        let sandboxID = "probe-schemata-\(program.chunkID)"
        let sandbox = try await workspaces.createSandbox(id: sandboxID)
        print("sandbox: \(sandbox.path)")
        do {
            let artifact = try await adapter.buildSchemataChunk(loweredSources: program.loweredSources, in: sandbox)
            print("BUILD SUCCEEDED, productHash=\(artifact.productHash ?? "nil")")
        } catch {
            anyFailed = true
            printFailure(error)
        }
        if !keep {
            try await workspaces.destroySandbox(at: sandbox)
        } else {
            print("kept sandbox at \(sandbox.path)")
        }
    }
    exit(anyFailed ? 1 : 0)

case "isolated":
    guard let mutationIDRaw = flagValue("--mutation-id", in: args) else { fail("isolated mode requires --mutation-id") }
    let mutationID = MutationID(rawValue: mutationIDRaw)
    guard let point = fullPlan.mutations.first(where: { $0.id == mutationID }) else {
        fail("mutation \(mutationIDRaw) not found in plan")
    }
    print("isolated build probe for \(point.id.rawValue) (\(point.operatorID)) at \(point.file):\(point.line)")

    let sandboxID = "probe-isolated-\(point.id.rawValue)"
    let sandbox = try await workspaces.createSandbox(id: sandboxID)
    print("sandbox: \(sandbox.path)")
    let targetFile = sandbox.appendingPathComponent(point.file)
    let applied = try MutationApplication.applyInPlace(point, fileAt: targetFile)
    print("applied: sourceBeforeHash=\(applied.evidence.sourceBeforeHash) sourceAfterHash=\(applied.evidence.sourceAfterHash)")

    var failed = false
    do {
        let artifact = try await adapter.buildMutant(applied, in: sandbox)
        print("BUILD SUCCEEDED, productHash=\(artifact.productHash ?? "nil")")
    } catch {
        failed = true
        printFailure(error)
    }
    if !keep {
        try await workspaces.destroySandbox(at: sandbox)
    } else {
        print("kept sandbox at \(sandbox.path)")
    }
    exit(failed ? 1 : 0)

default:
    fail("unknown mode \(mode); expected 'schemata' or 'isolated'")
}
