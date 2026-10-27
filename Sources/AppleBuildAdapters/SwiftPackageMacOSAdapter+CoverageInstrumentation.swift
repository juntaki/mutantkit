import Foundation
import MutationExecution
import MutationModel
import SwiftFrontend

extension SwiftPackageMacOSAdapter {
    /// The source files a coverage build had rewritten, with what they held before.
    struct StaticInitializerInstrumentation {
        let originals: [(url: URL, data: Data)]

        /// Puts the original sources back. The sandbox is the one the baseline ran in, and in isolated mode
        /// mutants are applied to it afterwards.
        func restore() {
            for (url, data) in originals { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Wraps the initializer of every `static let` and global in a closure so the instrumented build
    /// records the lines no test could otherwise be shown to have run (see
    /// `StaticInitializerCoverageWrapper`). Returns `nil`, with the sources untouched, when there is
    /// nothing to wrap or the rewritten package does not build with coverage: the measurement then
    /// proceeds exactly as it did without this step.
    func instrumentStaticInitializers(in workspace: URL, timeoutSeconds: Double) async -> StaticInitializerInstrumentation? {
        let package = resolvedWorkspace(workspace)
        let sources = package.appendingPathComponent("Sources", isDirectory: true)
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: sources.path) else { return nil }

        var originals: [(url: URL, data: Data)] = []
        for url in paths.filter({ $0.hasSuffix(".swift") }).sorted().map({ sources.appendingPathComponent($0) }) {
            guard let data = try? Data(contentsOf: url),
                  let rewritten = StaticInitializerCoverageWrapper.rewrite(
                      String(decoding: data, as: UTF8.self), isMainFile: url.lastPathComponent == "main.swift"
                  ),
                  (try? Data(rewritten.utf8).write(to: url, options: .atomic)) != nil
            else { continue }
            originals.append((url, data))
        }
        guard !originals.isEmpty else { return nil }

        let instrumentation = StaticInitializerInstrumentation(originals: originals)
        let built = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcrun,
            arguments: ["swift", "build", "--build-tests", "--enable-code-coverage"],
            workingDirectory: package,
            timeoutSeconds: timeoutSeconds,
            terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
        )
        guard built?.succeeded == true else {
            instrumentation.restore()
            return nil
        }
        return instrumentation
    }
}
