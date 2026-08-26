import Foundation
import MutationExecution
import MutationModel

/// Real auto-detection of an Xcode project/workspace's scheme, test
/// target(s), and a usable simulator destination — the pieces `mutantkit
/// init`'s generated config left the user to fill in by hand before Phase
/// C13, for every kind except SwiftPM.
///
/// Every answer here comes from asking the real tool (`xcodebuild -list`,
/// a scheme's own `.xcscheme` XML, `simctl list devices`), never from a
/// naming convention or a guess — the same standard `SwiftPMTargetResolver`
/// already holds itself to for the SwiftPM side of `init`.
public enum XcodeConfigDetector {
    public struct Detection: Sendable {
        /// `nil` when discovery found zero or more than one scheme —
        /// `init` cannot safely choose between several without guessing,
        /// matching `XcodeBuildAdapter.resolveScheme`'s own "will not
        /// choose for you" posture for an actual run.
        public let scheme: String?
        /// Every reason `scheme` came back `nil`, or empty when it did not.
        public let schemeCandidates: [String]
        /// Real test target names, parsed from the resolved scheme's own
        /// `<TestAction><Testables>` — empty when `scheme` is `nil`, or
        /// when the scheme's `.xcscheme` file could not be found/parsed.
        public let testTargets: [String]
        /// A real, currently-available simulator destination string, or
        /// `nil` when this project kind needs none (macOS) or none could
        /// be found.
        public let destination: String?
    }

    /// - Parameters:
    ///   - kind: only `.xcodeProject`/`.xcodeWorkspace` are detected;
    ///     every other kind returns an all-`nil`/empty `Detection`
    ///     immediately, without touching `xcodebuild` or `simctl` at all.
    public static func detect(
        kind: ProjectKind,
        projectFile: URL?,
        projectRoot: URL
    ) async -> Detection {
        guard kind == .xcodeProject || kind == .xcodeWorkspace, let projectFile else {
            return Detection(scheme: nil, schemeCandidates: [], testTargets: [], destination: nil)
        }

        let adapter = XcodeBuildAdapter(
            configuration: Configuration(),
            kind: kind,
            projectFile: projectFile,
            projectRoot: projectRoot
        )
        let schemes = await adapter.discoverSchemes(in: projectRoot)

        // The destination (which real simulator to use) is independent of
        // scheme resolution entirely -- computed unconditionally, so an
        // ambiguous-scheme project (the common case for anything beyond a
        // single-target toy) still gets a real, usable destination
        // suggestion instead of losing it to an unrelated ambiguity. Test
        // targets, unlike the destination, genuinely do depend on knowing
        // *which* scheme -- `<TestAction><Testables>` belongs to one
        // specific scheme document, so that part stays gated on having
        // resolved exactly one.
        let destination = await detectDestination(projectRoot: projectRoot)

        guard schemes.count == 1 else {
            return Detection(scheme: nil, schemeCandidates: schemes, testTargets: [], destination: destination)
        }
        let scheme = schemes[0]

        let testTargets = await testTargets(forScheme: scheme, projectRoot: projectRoot)

        return Detection(scheme: scheme, schemeCandidates: schemes, testTargets: testTargets, destination: destination)
    }

    // MARK: - Test targets, from the scheme's own .xcscheme

    /// Finds `<scheme>.xcscheme` anywhere under `projectRoot` (shared
    /// schemes live at `<container>/xcshareddata/xcschemes/<name>.xcscheme`,
    /// whether `<container>` is the `.xcodeproj` or the `.xcworkspace` a
    /// scheme happens to be defined at) and parses its `<TestAction>
    /// <Testables>` — the exact list Xcode itself uses to decide which
    /// targets a scheme tests. Never a naming-convention guess: a scheme
    /// named after its app target commonly tests a *different*, separately-
    /// named test bundle, which is exactly why this reads the real
    /// scheme document instead.
    static func testTargets(forScheme scheme: String, projectRoot: URL) async -> [String] {
        guard let schemeFile = findSchemeFile(named: scheme, under: projectRoot) else { return [] }
        guard let data = try? Data(contentsOf: schemeFile) else { return [] }
        return parseTestableBlueprintNames(from: data)
    }

    private static func findSchemeFile(named scheme: String, under root: URL) -> URL? {
        let targetName = "\(scheme).xcscheme"
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator where url.lastPathComponent == targetName {
            return url
        }
        return nil
    }

    /// Extracts every `BlueprintName` inside `<TestAction><Testables>...
    /// <TestableReference><BuildableReference BlueprintName="...">` — a
    /// small, targeted XML walk rather than a general-purpose `.xcscheme`
    /// model, since this is the only piece of that document `init`/`doctor`
    /// need.
    static func parseTestableBlueprintNames(from data: Data) -> [String] {
        let parser = XCSchemeTestablesParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.blueprintNames
    }

    private final class XCSchemeTestablesParser: NSObject, XMLParserDelegate {
        private(set) var blueprintNames: [String] = []
        private var insideTestables = false
        private var testablesDepth = 0
        private var currentDepth = 0

        // Tracks whether the `<TestableReference>` currently being walked
        // has `skipped = "YES"` — a real, common Xcode scheme state (a
        // disabled UI/integration test bundle within an otherwise-enabled
        // scheme), found by Codex review before this was committed as
        // done. A skipped testable is not one `xcodebuild
        // -only-testing:`/`test-without-building` would ever actually run,
        // so it must never be suggested into `tests.targets`.
        private var currentTestableIsSkipped = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            currentDepth += 1
            if elementName == "Testables" {
                insideTestables = true
                testablesDepth = currentDepth
            } else if insideTestables, elementName == "TestableReference" {
                currentTestableIsSkipped = attributeDict["skipped"] == "YES"
            } else if insideTestables, !currentTestableIsSkipped, elementName == "BuildableReference",
                      let name = attributeDict["BlueprintName"] {
                blueprintNames.append(name)
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "Testables", currentDepth == testablesDepth {
                insideTestables = false
            }
            currentDepth -= 1
        }
    }

    // MARK: - Destination, from a real simctl device list

    /// A real, currently-available iOS Simulator destination — the same
    /// `SimulatorPool` every real run already uses to discover devices,
    /// not a second, ad-hoc `simctl` invocation. Prefers an iPhone model
    /// (the same convention every competitor's own default targets),
    /// under whichever installed *iOS* runtime is numerically latest;
    /// `nil` when `simctl` itself is unavailable, lists nothing, or lists
    /// only non-iOS devices, so the caller can fall back to its own
    /// conservative default rather than fabricate a destination string
    /// naming a device this machine does not have.
    ///
    /// Two real bugs found by Codex review before this was committed as
    /// done: (1) comparing `runtimeIdentifier` as raw strings sorts
    /// `iOS-9-*` ahead of `iOS-26-*` and `iOS-26-10` behind `iOS-26-9` —
    /// wrong once any version component reaches two digits, so this now
    /// compares numeric version components instead, the same fix Phase
    /// C10 already made for `XcodeBuildAdapter`'s own runtime comparison.
    /// (2) falling back to *any* device (not just iOS ones) once no
    /// `iPhone`-named device existed, then always labeling the result
    /// `platform=iOS Simulator` regardless — a machine with only tvOS/
    /// watchOS/visionOS runtimes installed got a destination string for a
    /// platform it does not have. Now restricted to iOS-runtime devices
    /// only, and returns `nil` (never a wrong-platform guess) when none
    /// exist. Built as `platform=iOS Simulator,name=<device>` — matching
    /// the convention every other config-facing destination string in
    /// this codebase uses (`InitCommand.defaultDestination`'s own
    /// hardcoded fallback, the pre-C13 behavior this replaces), since a
    /// generated `mutantkit.yml` is meant to be human-read and -edited;
    /// `SimulatorDevice.destination`'s own UDID-addressed form exists for
    /// precise per-worker lease addressing during a real run, a different
    /// concern from what belongs in a hand-editable config file. The
    /// platform label is safe to hardcode here specifically *because*
    /// `candidates` is already restricted to real iOS-runtime devices
    /// above — never true before that filter existed.
    static func detectDestination(projectRoot: URL) async -> String? {
        let pool = SimulatorPool(workingDirectory: projectRoot)
        guard let devices = try? await pool.availableDevices(), !devices.isEmpty else { return nil }
        return selectDestination(from: devices)
    }

    /// The pure selection logic, factored out of `detectDestination` so it
    /// can be unit-tested directly against a hand-built device list rather
    /// than only through a real, machine-dependent `simctl` call — the two
    /// real bugs this fixes (below) are both about *which* device gets
    /// chosen, not about talking to `simctl` at all.
    static func selectDestination(from devices: [SimulatorDevice]) -> String? {
        let iOSDevices = devices.filter { $0.runtimeIdentifier.localizedCaseInsensitiveContains("SimRuntime.iOS") }
        guard !iOSDevices.isEmpty else { return nil }

        let iPhones = iOSDevices.filter { $0.name.hasPrefix("iPhone") }
        let candidates = iPhones.isEmpty ? iOSDevices : iPhones
        guard let chosen = candidates.max(by: {
            iOSVersionComponents(of: $0.runtimeIdentifier).lexicographicallyPrecedes(iOSVersionComponents(of: $1.runtimeIdentifier))
        }) else { return nil }
        return "platform=iOS Simulator,name=\(chosen.name)"
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-3-1` → `[26, 3, 1]`.
    /// Only ever called on identifiers already confirmed to contain
    /// `SimRuntime.iOS` by `selectDestination`'s own filter above, so an
    /// empty result here should not occur in practice — compared via
    /// `lexicographicallyPrecedes`, which treats a shorter-but-matching
    /// prefix as older, matching `XcodeBuildAdapter.runtimeIsOlder`'s own
    /// semantics.
    static func iOSVersionComponents(of runtimeIdentifier: String) -> [Int] {
        guard let range = runtimeIdentifier.range(of: "iOS-", options: .caseInsensitive) else { return [] }
        return runtimeIdentifier[range.upperBound...].split(separator: "-").compactMap { Int($0) }
    }
}
