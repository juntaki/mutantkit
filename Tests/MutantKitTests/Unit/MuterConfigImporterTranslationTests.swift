import Foundation
import MutationModel
import MuterCompatibility
import Testing

/// `MuterConfigImporter` had real, user-facing translation logic with no
/// test coverage: the existing suites (`MuterConfigImporterExcludeCallsTests`,
/// `MuterConfigImporterVersionTests`) each scope narrowly to one field they
/// were written for, always against the same `xcodebuild -project` fixture.
/// This fills the rest of the decision tree the importer actually makes:
/// which project kind an executable/argument shape infers to, what happens
/// when it cannot be inferred, which arguments are extracted versus left
/// over, and which fields have genuinely no equivalent and are reported as
/// dropped rather than silently ignored.
@Suite("MuterConfigImporter: translation decision tree")
struct MuterConfigImporterTranslationTests {
    private func imported(_ yaml: String, sourceName: String = "muter.conf.yml") throws -> MuterImport {
        try MuterConfigImporter().importConfiguration(from: Data(yaml.utf8), sourceName: sourceName)
    }

    private func entry(_ imported: MuterImport, field: String) throws -> ImportReport.Entry {
        try #require(imported.report.entries.first { $0.field == field }, "no report entry for field '\(field)'")
    }

    // MARK: - xcodebuild: workspace vs project vs neither

    @Test("xcodebuild -workspace infers project.kind xcodeWorkspace and records the inference")
    func xcodebuildWorkspaceInfersWorkspaceKind() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -workspace
          - App.xcworkspace
          - -scheme
          - App
        """)

        #expect(result.configuration.project.kind == .xcodeWorkspace)
        #expect(result.configuration.project.path == "App.xcworkspace")

        let projectEntry = try entry(result, field: "executable + arguments")
        #expect(projectEntry.disposition == .translated)
        #expect(projectEntry.mutantkitValue?.contains("xcodeWorkspace") == true)
    }

    @Test("xcodebuild -project infers project.kind xcodeProject and records the inference")
    func xcodebuildProjectInfersProjectKind() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        """)

        #expect(result.configuration.project.kind == .xcodeProject)
        #expect(result.configuration.project.path == "App.xcodeproj")

        let projectEntry = try entry(result, field: "executable + arguments")
        #expect(projectEntry.disposition == .translated)
        #expect(projectEntry.mutantkitValue?.contains("xcodeProject") == true)
    }

    @Test("xcodebuild with neither -workspace nor -project cannot infer a kind and needs review")
    func xcodebuildWithNeitherFlagNeedsReview() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -scheme
          - App
        """)

        #expect(result.configuration.project.kind == .auto)

        let projectEntry = try entry(result, field: "executable + arguments")
        #expect(projectEntry.disposition == .needsReview)
        #expect(projectEntry.detail.contains("could not be inferred"))
    }

    @Test("xcodebuild extracts -scheme, -destination and -derivedDataPath as translated entries")
    func xcodebuildExtractsScopedArguments() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
          - -destination
          - platform=iOS Simulator,name=iPhone 16
          - -derivedDataPath
          - .derived
        """)

        #expect(result.configuration.project.scheme == "App")
        #expect(result.configuration.project.destination == "platform=iOS Simulator,name=iPhone 16")
        #expect(result.configuration.project.derivedDataPath == ".derived")

        for field in ["arguments -scheme", "arguments -destination", "arguments -derivedDataPath"] {
            #expect(try entry(result, field: field).disposition == .translated)
        }
    }

    // MARK: - swift / unknown executables

    @Test("A swift executable infers swiftPackageMacOS and needs review, not translated")
    func swiftExecutableInfersSwiftPackageMacOS() throws {
        let result = try imported("""
        executable: /usr/bin/swift
        arguments:
          - test
        """)

        #expect(result.configuration.project.kind == .swiftPackageMacOS)

        let projectEntry = try entry(result, field: "executable + arguments")
        #expect(projectEntry.disposition == .needsReview)
        #expect(projectEntry.detail.contains("swiftPackageApple"))
    }

    @Test("An unrecognized executable cannot infer any project kind and needs review")
    func unknownExecutableNeedsReview() throws {
        let result = try imported("""
        executable: /usr/bin/fastlane
        arguments:
          - scan
        """)

        #expect(result.configuration.project.kind == .auto)

        let projectEntry = try entry(result, field: "executable")
        #expect(projectEntry.disposition == .needsReview)
        #expect(projectEntry.muterValue == "/usr/bin/fastlane")
    }

    // MARK: - Leftover arguments

    @Test("Arguments not recognized as a consumed flag or subcommand are reported as leftovers")
    func unrecognizedArgumentsAreReportedAsLeftovers() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - test
          - -project
          - App.xcodeproj
          - -scheme
          - App
          - -quiet
          - -resultBundlePath
          - results.xcresult
        """)

        let leftovers = try entry(result, field: "arguments (remaining)")
        #expect(leftovers.disposition == .needsReview)
        #expect(leftovers.muterValue == "-quiet -resultBundlePath results.xcresult")
        #expect(leftovers.mutantkitValue == nil)
    }

    @Test("A command with no unrecognized arguments records no leftover entry")
    func noLeftoversWhenEveryArgumentIsConsumed() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - test
          - -project
          - App.xcodeproj
          - -scheme
          - App
        """)

        #expect(!result.report.entries.contains { $0.field == "arguments (remaining)" })
    }

    // MARK: - Sources / exclude

    @Test("A non-empty exclude list is carried over verbatim, replacing the defaults")
    func nonEmptyExcludeIsCarriedOverVerbatim() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        exclude:
          - Vendor/
          - Generated/
        """)

        #expect(result.configuration.sources.exclude == ["Vendor/", "Generated/"])

        let excludeEntry = try entry(result, field: "exclude")
        #expect(excludeEntry.disposition == .partiallyTranslated)
        #expect(excludeEntry.detail.contains("NOT excluded"))
    }

    @Test("An empty exclude list reports that the defaults apply, without carrying anything over")
    func emptyExcludeReportsDefaultsApply() throws {
        let result = try imported("""
        executable: /usr/bin/xcodebuild
        arguments:
          - -project
          - App.xcodeproj
          - -scheme
          - App
        """)

        let excludeEntry = try entry(result, field: "exclude")
        #expect(excludeEntry.disposition == .translated)
        #expect(excludeEntry.muterValue == "(none)")
    }
}
