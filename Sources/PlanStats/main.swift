import AppleBuildAdapters
import Foundation
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend

// TEMP diagnostic tool, not intended to be committed. Answers, from a
// plan.json alone (no test execution, no runtime outcomes), exactly what
// the real formal run's own SchemataChunkPlanner.plan would embed vs.
// fall back, broken down by operator, plus chunk composition — the static
// half of the "why is this run slow" diagnostic.
//
// Usage: PlanStats <plan.json> <projectRoot>

setvbuf(stdout, nil, _IONBF, 0)

guard CommandLine.arguments.count >= 3 else {
    print("usage: PlanStats <plan.json> <projectRoot>")
    exit(1)
}
let planPath = CommandLine.arguments[1]
let projectRoot = URL(fileURLWithPath: CommandLine.arguments[2])
let planData = try Data(contentsOf: URL(fileURLWithPath: planPath))
let mutationPlan = try MutationPlan.decode(from: planData)

// Mutation count by operator.
var countByOperator: [String: Int] = [:]
for m in mutationPlan.mutations {
    countByOperator[m.operatorID, default: 0] += 1
}
print("=== Mutation count by operator ===")
for (op, count) in countByOperator.sorted(by: { $0.key < $1.key }) {
    print("  \(op): \(count)")
}
print("  TOTAL: \(mutationPlan.mutations.count)")

// Read every source file the plan references.
var sources: [String: Data] = [:]
for file in Set(mutationPlan.mutations.map(\.file)) {
    sources[file] = try Data(contentsOf: projectRoot.appendingPathComponent(file))
}

// Resolve targets exactly like the real formal run does — branching the
// same way `SchemataRunOrchestration.classify` now does: a bare
// `.xcodeproj` directory (no `Package.swift`) means `SwiftPMTargetResolver`
// would fail outright (`swift package describe` has no manifest to read),
// so this diagnostic tool picks the resolver by the same evidence
// `ProjectDetector` uses — presence of `Package.swift` vs. an `.xcodeproj`
// — rather than requiring a `--kind` flag for what is meant to stay a
// TEMP, throwaway tool. Top-level `await` in a main.swift file implicitly
// makes this file's entry point async — no Task/semaphore bridging needed
// (and that pattern deadlocks here: a Task{} spawned from top-level code
// has no one pumping the runloop that blocks on it via
// DispatchSemaphore.wait()).
let hasPackageManifest = FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Package.swift").path)
let backendID: String
let targetInfo: [String: [SchemataTargetInfo]]
if hasPackageManifest {
    print("\n=== Resolving targets (swift package describe)... ===")
    targetInfo = try await SwiftPMTargetResolver.resolveTargetInfo(projectRoot: projectRoot)
    backendID = "swiftpm-schemata-v1"
} else {
    print("\n=== Resolving targets (project.pbxproj + xcodebuild -showBuildSettings)... ===")
    targetInfo = try await XcodeTargetResolver.resolveTargetInfo(projectRoot: projectRoot)
    backendID = "xcode-schemata-v1"
}
print("\n=== Target resolution ===")
print("  \(targetInfo.count) files resolved to target info")

let targetFiles = Set(targetInfo.keys).subtracting(sources.keys)
for file in targetFiles {
    sources[file] = try Data(contentsOf: projectRoot.appendingPathComponent(file))
}

let registry = try SchemataLowererRegistry()
let backend = SchemataBackendInfo(
    backendID: backendID, backendVersion: 1,
    toolchainHash: "n/a", buildArgumentsHash: mutationPlan.configurationHash
)

let planResult = try SchemataChunkPlanner.plan(
    mutationPlan: mutationPlan, registry: registry, sources: sources, targetInfo: targetInfo, backend: backend
)

let mutationsByID = Dictionary(uniqueKeysWithValues: mutationPlan.mutations.map { ($0.id, $0) })

var embeddedByOperator: [String: Int] = [:]
var fallbackByOperator: [String: Int] = [:]
var fallbackReasonCounts: [String: Int] = [:]

for entry in planResult.schemataPlan.entries {
    guard let m = mutationsByID[entry.mutationID] else { continue }
    if entry.isEmbedded {
        embeddedByOperator[m.operatorID, default: 0] += 1
    } else {
        fallbackByOperator[m.operatorID, default: 0] += 1
        let reasonLabel = entry.fallbackReason.map { String(describing: $0) } ?? "unknown"
        // Collapse to the reason's "case name" prefix for readability.
        let shortReason = reasonLabel.split(separator: "(").first.map(String.init) ?? reasonLabel
        fallbackReasonCounts[shortReason, default: 0] += 1
    }
}

print("\n=== Planner-embedded vs fallback, by operator ===")
for op in countByOperator.keys.sorted() {
    let embedded = embeddedByOperator[op] ?? 0
    let fallback = fallbackByOperator[op] ?? 0
    let lowererRegistered = registry.lowerer(forOperatorID: op) != nil
    print("  \(op): embedded=\(embedded) fallback=\(fallback) lowererRegistered=\(lowererRegistered)")
}

let totalEmbedded = planResult.schemataPlan.entries.count(where: \.isEmbedded)
let totalFallback = planResult.schemataPlan.entries.count - totalEmbedded
print("\n=== Overall ===")
print("  planned embedded:  \(totalEmbedded)")
print("  planned fallback:  \(totalFallback)")
let ratio = mutationPlan.mutations.isEmpty ? 0.0 : Double(totalEmbedded) / Double(mutationPlan.mutations.count)
print("  effective ratio:   \(String(format: "%.3f", ratio))")

print("\n=== Fallback reason distribution ===")
for (reason, count) in fallbackReasonCounts.sorted(by: { $0.value > $1.value }) {
    print("  \(reason): \(count)")
}

print("\n=== Chunk composition ===")
print("  chunk count: \(planResult.programs.count)")
let chunkSizes = planResult.programs.map(\.entries.count).sorted()
if !chunkSizes.isEmpty {
    print("  chunk sizes: \(chunkSizes)")
    print("  min=\(chunkSizes.first!) max=\(chunkSizes.last!) mean=\(String(format: "%.1f", Double(chunkSizes.reduce(0, +)) / Double(chunkSizes.count)))")
}
