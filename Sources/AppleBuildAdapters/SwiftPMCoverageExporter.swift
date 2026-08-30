import Foundation
import MutationExecution

/// Turns one test's raw `.profraw` (from `SwiftPMDirectCoverageRunner`) into
/// the exact same `llvm.coverage.json.export` JSON shape `swift test
/// --enable-code-coverage`'s own `codecov/*.json` files already are — so
/// this fast path feeds `SourceCoverageReader` the identical evidence
/// format the serial oracle does, rather than defining a second meaning for
/// "coverage."
///
/// `llvm-profdata merge` is required even for a single `.profraw`: `llvm-cov
/// export` only reads the indexed `.profdata` form, never a raw profile
/// directly (confirmed against the real toolchain). "Merge" here is always
/// one test's own profile into one profdata — this type never combines two
/// different tests' profiles, which would destroy the per-test separability
/// the whole point of this backend is to produce.
enum SwiftPMCoverageExporter {
    enum ExportResult: Sendable, Equatable {
        case exported(Data)
        case unavailable(reason: String)
    }

    /// - Parameters:
    ///   - profileURL: one test's own `.profraw`, already confirmed to
    ///     exist by `SwiftPMDirectCoverageRunner`.
    ///   - testBundleBinary: the same Mach-O binary the profile was
    ///     recorded against — `llvm-cov export` needs it to resolve which
    ///     source regions the profile's counters refer to.
    ///   - scratchDirectory: where the intermediate `.profdata` is written.
    static func export(
        profileURL: URL,
        testBundleBinary: URL,
        scratchDirectory: URL,
        timeoutSeconds: Double = 60,
        processRunner: ProcessRunner = defaultProcessRunner
    ) async -> ExportResult {
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            return .unavailable(reason: "no profile at \(profileURL.path)")
        }

        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let profdataURL = scratchDirectory.appendingPathComponent("\(UUID().uuidString).profdata")

        let mergeResult: ProcessResult
        do {
            mergeResult = try await processRunner(
                ToolPaths.xcrun,
                ["llvm-profdata", "merge", "-sparse", profileURL.path, "-o", profdataURL.path],
                scratchDirectory,
                timeoutSeconds
            )
        } catch {
            return .unavailable(reason: "could not launch llvm-profdata: \(error)")
        }
        guard mergeResult.succeeded, mergeResult.outputComplete else {
            return .unavailable(reason: "llvm-profdata merge failed or produced incomplete output")
        }

        let exportResult: ProcessResult
        do {
            exportResult = try await processRunner(
                ToolPaths.xcrun,
                ["llvm-cov", "export", "-instr-profile=\(profdataURL.path)", testBundleBinary.path],
                scratchDirectory,
                timeoutSeconds
            )
        } catch {
            return .unavailable(reason: "could not launch llvm-cov: \(error)")
        }
        guard exportResult.succeeded, exportResult.outputComplete else {
            return .unavailable(reason: "llvm-cov export failed or produced incomplete output")
        }

        return .exported(exportResult.standardOutput)
    }
}
