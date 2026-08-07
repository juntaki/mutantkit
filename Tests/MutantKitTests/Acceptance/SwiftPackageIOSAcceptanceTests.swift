import Foundation
import MutationModel
import Testing

/// A Swift package that declares only iOS.
///
/// This fixture exists because of a specific, real failure: routing an iOS-only
/// package through `swift test` compiles it for the host, where UIKit does not
/// resolve, and the result is a compile error that appears to blame the user's
/// code. The package has no macOS slice at all, so the *only* correct answer is
/// to detect that from the manifest and build it with xcodebuild against a
/// simulator. `BadgeFormatter` imports UIKit on purpose: it makes the wrong
/// decision fail loudly instead of passing by accident.
///
/// It also covers a second thing nothing else does — the scheme is discovered
/// rather than configured. A SwiftPM package's scheme is named for the package,
/// and guessing a name by convention names something that does not exist.
@Suite("Acceptance: Swift package for iOS", .enabled(if: Acceptance.simulatorEnabled))
struct SwiftPackageIOSAcceptanceTests {
    /// No `scheme:` on purpose — the adapter has to find it. The destination is
    /// whatever iPhone this machine has, so the suite is not pinned to one Xcode.
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: swiftPackageApple
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 2
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "SwiftPackageIOS", configuration: configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("An iOS-only package builds, runs on a simulator, and reconciles")
    func iosPackageRunsEndToEnd() throws {
        let run = try self.run()

        // A green baseline here is the whole claim: the package linked UIKit and
        // its tests ran, which `swift test` could not have achieved.
        #expect(run.report.baseline.passed)
        #expect(run.report.baseline.testSummary?.total == 2)

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        // 6, not 4: the default operator profile now also includes
        // `return-value-replacement` (one candidate, `text(forCount:)`'s
        // `return "99+"`) and `ternary-branch-swap` (one candidate,
        // `color(forCount:)`'s ternary) on top of the four
        // `relational-operator-replacement` candidates below. See
        // `survivorsAreExactlyTheUncoveredOnes` for what each one does.
        #expect(integrity.planned == 6)
        #expect(integrity.sourceApplied == 6)
        #expect(integrity.buildObserved == 6)
        #expect(run.report.score != nil)
    }

    /// Asserts per operator, not just a total count, so that the next operator
    /// the default profile gains can't silently re-break this test the same
    /// way `return-value-replacement` and `ternary-branch-swap` did: either
    /// it doesn't touch this fixture's code shapes at all, or its own
    /// expected outcome has to be added here explicitly.
    ///
    /// `text(forCount:)` is tested at 99 and 100 — both sides of the boundary
    /// — so nothing about `> 99` (nor its literal return value) survives.
    /// `isProminent` and `color(forCount:)` are not tested at all, so both of
    /// their mutants survive.
    @Test("Exactly the uncovered mutations survive")
    func survivorsAreExactlyTheUncoveredOnes() throws {
        let run = try self.run()

        // relational-operator-replacement on `count > 99`: both flipped
        // comparisons are killed by the boundary tests at 99 and 100.
        #expect(run.killed.contains(
            .init(declaration: "text(forCount:)", original: ">", replacement: ">=")
        ))
        #expect(run.killed.contains(
            .init(declaration: "text(forCount:)", original: ">", replacement: "<=")
        ))

        // return-value-replacement on `return "99+"`: replaced with `""`,
        // caught by the same boundary test at count 100.
        #expect(run.killed.contains(
            .init(declaration: "text(forCount:)", original: "\"99+\"", replacement: "\"\"")
        ))

        // relational-operator-replacement on `isProminent`'s `count >= 10`:
        // untested, so both flipped comparisons survive.
        let survivors = run.mutations(withOutcome: .survived)
        #expect(survivors.contains(
            .init(declaration: "isProminent(count:)", original: ">=", replacement: ">")
        ))
        #expect(survivors.contains(
            .init(declaration: "isProminent(count:)", original: ">=", replacement: "<")
        ))

        // ternary-branch-swap on `color(forCount:)`: also untested, so its
        // swapped branches survive too.
        #expect(survivors.contains(
            .init(
                declaration: "color(forCount:)",
                original: "isProminent(count: count) ? .systemRed : .systemGray",
                replacement: "isProminent(count: count) ? .systemGray : .systemRed"
            )
        ))

        // Exactly these six candidates exist for this fixture — checking
        // the total alongside the individual memberships above means an
        // operator that adds a seventh, unaccounted-for candidate fails
        // loudly instead of passing by accident.
        #expect(run.killed.count + survivors.count == 6)
    }

    /// XCTest results here come from the `.xcresult`, not from stdout. Counts
    /// proving present is what distinguishes a parsed result bundle from a guess.
    @Test("XCTest outcomes are read from the result bundle")
    func xctestCountsComeFromTheResultBundle() throws {
        let run = try self.run()

        for result in run.report.results where result.outcome == .killedByAssertion {
            let summary = try #require(result.testSummary)
            #expect(summary.total == 2)
            #expect(summary.failed >= 1)
            #expect(!summary.failingTests.isEmpty, "the bundle should name the test that caught it")
        }
    }

    @Test("Detection routes an iOS-only package away from swift test")
    func detectionChoosesXcodebuild() throws {
        let directory = try Acceptance.stageFixture("SwiftPackageIOS")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Only `project.destination` is set — no `project.kind` — so
        // `doctor` still has to detect the kind itself. Without an explicit
        // destination, resolution falls back to a hardcoded "iPhone 16",
        // which does not exist on every machine; naming a discovered
        // destination instead (as every other acceptance test in this suite
        // already does via `iPhoneDestination()`) keeps this test about
        // detection, not about which simulators happen to be installed.
        try """
        version: 1
        project:
          destination: \(try Acceptance.iPhoneDestination())
        """.write(to: directory.appendingPathComponent("mutantkit.yml"), atomically: true, encoding: .utf8)

        let doctor = try Acceptance.run(["doctor", "--skip-build"], in: directory)
        #expect(doctor.output.contains("swiftPackageApple"))
        #expect(doctor.output.contains("xcodebuild"))
    }
}
