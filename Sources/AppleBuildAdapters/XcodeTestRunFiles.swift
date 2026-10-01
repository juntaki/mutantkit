import Foundation
import MutationExecution
import MutationModel

// MARK: - .xctestrun

//
// Extracted from `XcodeBuildAdapter.swift` as part of this project's
// internal execution-engine restructuring, its own "safe file-split half"
// (see its own, private planning notes, not part of this public repo, for
// the full rationale). None of the three members below (`XCTestRunLocator`,
// its `xctestrunVariant` sibling, `SchemeListJSON`) carry any of
// `XcodeBuildAdapter`'s own stored state (`configuration`, `simulators`,
// `resolvedDestination`, ...) — each is a pure, self-contained ".xctestrun /
// scheme-JSON file shape" concern already either free-standing
// (`XCTestRunLocator`, `SchemeListJSON`) or trivially extractable
// (`xctestrunVariant`, formerly a `private static func` inside
// `XcodeBuildAdapter`'s `SchemataTestable` extension). A pure move: no
// stored state relocated, no signature or behavior changed, so
// `swift build --build-tests` alone is the correct verification bar (same
// standard this plan's own Step 2/Step 3 used for other purely-additive/
// purely-mechanical moves).

/// Finds the `.xctestrun` that `build-for-testing` produced.
enum XCTestRunLocator {
    /// Searches `Build/Products` for the file.
    ///
    /// Searched, never constructed. The name encodes the scheme, the platform, the
    /// SDK version and the architecture — a real one reads
    /// `Probe-Package_Probe-Package_macosx26.5-arm64.xctestrun` — and every one of
    /// those varies by machine and by Xcode release. Building that string from a
    /// template produces a path that does not exist, and the resulting "file not
    /// found" gets read as a broken project rather than a broken guess.
    static func locate(in productsDirectory: URL, command: CommandRecord) throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: productsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        let found = contents.filter { $0.pathExtension == "xctestrun" }.sorted { $0.path < $1.path }

        switch found.count {
        case 1:
            return found[0]
        case 0:
            let siblings = contents.map(\.lastPathComponent).sorted()
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: """
                build-for-testing succeeded but left no .xctestrun in \
                \(productsDirectory.path). That directory contains \
                \(siblings.isEmpty ? "nothing" : siblings.joined(separator: ", ")). \
                The scheme probably has no test target enabled — check its Test action \
                in Xcode.
                """,
                command: command,
                output: ""
            )
        default:
            let names = found.map(\.lastPathComponent).joined(separator: ", ")
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: """
                \(found.count) .xctestrun files are present in \(productsDirectory.path) \
                (\(names)) and mutantkit will not guess which one to run. This usually \
                means several test plans or destinations were built; narrow \
                project.destination or the scheme's test plan in mutantkit.yml.
                """,
                command: command,
                output: ""
            )
        }
    }

    enum VariantError: Error, CustomStringConvertible {
        case malformed(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case let .malformed(path): "malformed .xctestrun at \(path)"
            case let .writeFailed(path): "could not write .xctestrun variant at \(path)"
            }
        }
    }

    /// Writes the variant *next to* `base`, in the same directory — not
    /// under some other convenience location like `.mutantkit/`. An
    /// `.xctestrun`'s own paths are resolved relative to `__TESTROOT__`,
    /// which Xcode derives from wherever the `.xctestrun` file itself
    /// physically sits, not from any field recorded inside it. Confirmed
    /// the hard way: a variant written to a different directory than the
    /// original resolved its test bundle path relative to *that*
    /// directory instead, and `test-without-building` failed with
    /// "Missing test product" for a bundle that, moments earlier, the
    /// original (unmoved) `.xctestrun` found without trouble.
    static func writingVariant(mergingEnvironment environment: [String: String], into base: URL) throws -> URL {
        guard var plist = NSDictionary(contentsOf: base) as? [String: Any] else {
            throw VariantError.malformed(base.path)
        }

        // Same two on-disk shapes `bundleIdentifiers(inXCTestRun:)` above
        // already handles: format version 2 nests each real test target
        // under `TestConfigurations[].TestTargets[]`; version 1 puts every
        // target directly at the top level next to `__xctestrun_metadata__`.
        // Only handling the flat v1 shape here silently drops every
        // injected environment variable on a version-2 `.xctestrun` (the
        // shape Xcode 26 generates): `TestConfigurations`'s value is an
        // array, so `as? [String: Any]` fails and the whole key is skipped,
        // while the two top-level keys that *do* happen to be dictionaries
        // (`ContainerInfo`, `TestPlan`) are not test targets at all and
        // silently absorb the write instead.
        if var configurations = plist["TestConfigurations"] as? [[String: Any]] {
            for configIndex in configurations.indices {
                guard var targets = configurations[configIndex]["TestTargets"] as? [[String: Any]] else { continue }
                for targetIndex in targets.indices {
                    var targetEnvironment = targets[targetIndex]["EnvironmentVariables"] as? [String: String] ?? [:]
                    for (variable, value) in environment { targetEnvironment[variable] = value }
                    targets[targetIndex]["EnvironmentVariables"] = targetEnvironment
                }
                configurations[configIndex]["TestTargets"] = targets
            }
            plist["TestConfigurations"] = configurations
        } else {
            for key in plist.keys where key != "__xctestrun_metadata__" {
                guard var target = plist[key] as? [String: Any] else { continue }
                var targetEnvironment = target["EnvironmentVariables"] as? [String: String] ?? [:]
                for (variable, value) in environment { targetEnvironment[variable] = value }
                target["EnvironmentVariables"] = targetEnvironment
                plist[key] = target
            }
        }

        let variant = base.deletingLastPathComponent().appendingPathComponent("variant-\(UUID().uuidString).xctestrun")
        // `NSDictionary.write(to:atomically:)` is the non-throwing
        // Objective-C-era API — `try` on it compiles but silently
        // discards a `false` (failure) return, exactly the kind of quiet
        // failure this whole proof chain exists to refuse. The `Bool`
        // result is checked explicitly instead.
        guard (plist as NSDictionary).write(to: variant, atomically: true) else {
            throw VariantError.writeFailed(variant.path)
        }
        return variant
    }
}

// MARK: - JSON

/// `xcodebuild -list -json`, which reports under `workspace` or `project`
/// depending on what it was pointed at.
enum SchemeListJSON {
    private struct Payload: Decodable {
        struct Container: Decodable {
            let name: String
            let schemes: [String]?
            let targets: [String]?
        }

        let workspace: Container?
        let project: Container?
    }

    static func schemes(from data: Data) -> [String] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return payload.workspace?.schemes ?? payload.project?.schemes ?? []
    }

    static func targets(from data: Data) -> [String] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return payload.workspace?.targets ?? payload.project?.targets ?? []
    }
}
