import Foundation
import Testing

/// GitHub runs a `shell: bash` step as
/// `bash --noprofile --norc -eo pipefail {0}`, and the default shell as
/// `bash -e {0}`. Either way `-e` is on, so the first unprotected command
/// that fails ends the step *there* — every later line in that `run:`
/// block is dead code on exactly the runs where it was supposed to act.
///
/// That is not hypothetical. `ci.yml`'s `Acceptance` step read
/// `test_exit=$?` straight after `swift test ... | tee acceptance.log`,
/// and below it ran `assert-tests-ran.sh` and a documented, narrowly
/// scoped retry for a known `xcodebuild` flake. On the run that prompted
/// this test, all three of the retry's conditions held, no `::warning::`
/// was emitted, and `assert-tests-ran.sh`'s own unconditional "-- OK"
/// line was missing from the log — the script never got past the
/// pipeline. The retry had never once fired since the day it was written,
/// and nothing said so: the job failed, which is what it would have done
/// anyway.
///
/// `$?` is the reliable marker for this shape, because reading it only
/// makes sense when the previous command is allowed to fail. So: any
/// `run:` block that reads `$?` must have turned `-e` off first.
/// `release-validation.yml`'s acceptance steps already did (`set +e`);
/// `ci.yml`'s did not.
///
/// Reads the real, checked-in workflow files rather than a fixture, for
/// the same reason `CIAcceptanceMatrixClassificationTests` does: a future
/// edit is then checked automatically, without anyone having to remember
/// this file exists.
@Suite("Workflow steps that read $? must disable errexit first")
struct WorkflowErrexitCaptureTests {
    /// The workflows live at the repo root in the published tree and under
    /// `oss-public/` in the full development checkout. Both are real, and
    /// *both* are returned when both exist rather than the first one found:
    /// the development checkout has its own `.github/workflows` too, and
    /// taking only the first match meant this test silently scanned those
    /// two files and never the projected ones — which is how the first
    /// version of it passed against a deliberately reintroduced bug.
    private static func workflowsDirectories() -> [URL] {
        let root = Acceptance.packageRoot
        return [
            root.appendingPathComponent(".github/workflows"),
            root.appendingPathComponent("oss-public/.github/workflows")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether a `set` line turns errexit on (`true`), off (`false`), or
    /// leaves it alone (`nil`).
    ///
    /// `-o pipefail` must not read as `-e` just because its option name is
    /// two tokens away, and `-euo` must read as `-e` because it is.
    static func errexitChange(in line: String) -> Bool? {
        var tokens = line.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard tokens.first == "set" else { return nil }
        tokens.removeFirst()
        var change: Bool?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard let sign = token.first, sign == "-" || sign == "+" else { continue }
            let flags = token.dropFirst()
            if flags.contains("o") {
                index += 1 // the option name belongs to `-o`, not to this cluster
                continue
            }
            if flags.contains("e") { change = sign == "-" }
        }
        return change
    }

    private static func workflowFiles() throws -> [URL] {
        try workflowsDirectories()
            .flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "yml" || $0.pathExtension == "yaml" }
            .sorted { $0.path < $1.path }
    }

    /// One `run:` block, as the lines between a `run:` line and the next
    /// line at or below its own indentation.
    ///
    /// Shell comments are dropped. They are prose, and prose in this
    /// repository quotes shell: the comment explaining why the
    /// `Acceptance` step needs `set +e` contains the literal
    /// `test_exit=$?`, and the first version of this test dutifully
    /// flagged it.
    private struct RunBlock {
        let startLine: Int
        let lines: [(number: Int, text: String)]
    }

    private func runBlocks(in source: String) -> [RunBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [RunBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("run:") else {
                index += 1
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            var body: [(Int, String)] = []
            var cursor = index + 1
            while cursor < lines.count {
                let candidate = lines[cursor]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if !candidateTrimmed.isEmpty, candidate.prefix { $0 == " " }.count <= indent { break }
                if !candidateTrimmed.hasPrefix("#") { body.append((cursor + 1, candidate)) }
                cursor += 1
            }
            blocks.append(RunBlock(startLine: index + 1, lines: body))
            index = cursor
        }
        return blocks
    }

    /// The structural rule, stated so that neither of the two ways this
    /// has already gone wrong can satisfy it: a status read must be the
    /// right-hand side of `||` on the same logical line as the command it
    /// is reading — unless it sits inside an explicit `set +e` … `set -e`
    /// bracket, which is the other correct way to say the same thing.
    ///
    /// `set +e` with no matching `set -e` is *not* accepted, and that is
    /// the whole distinction: a tight bracket exempts the one command
    /// whose failure is being inspected; an unclosed `set +e` silences
    /// every command after it, including ones added later by someone who
    /// never read this rule. `action-smoke-test.yml` already had two
    /// correct brackets when this test was written, and the first version
    /// of this rule flagged both.
    @Test("Every workflow status read is captured with `|| var=$?` or inside a set +e bracket")
    func everyStatusCaptureIsExemptFromErrexit() throws {
        let files = try Self.workflowFiles()
        // A scan that found nothing is indistinguishable from a clean scan,
        // and that is exactly how this test's own first version reported
        // success while looking at the wrong directory.
        #expect(
            files.contains { $0.lastPathComponent == "ci.yml" },
            "expected to find ci.yml under \(Self.workflowsDirectories().map(\.path))"
        )

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for block in runBlocks(in: source) {
                var errexitOn = true
                for line in block.lines {
                    if let change = Self.errexitChange(in: line.text) { errexitOn = change }
                    guard line.text.contains("=$?"), errexitOn else { continue }
                    let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                    #expect(
                        trimmed.contains("|| ") && trimmed.hasSuffix("=$?"),
                        """
                        \(file.lastPathComponent):\(line.number) reads `$?` on its own line, with errexit \
                        on. GitHub runs a `shell: bash` step as \
                        `bash --noprofile --norc -eo pipefail {0}`, so the failing command this is meant \
                        to inspect ends the step before this line runs. Write it as `cmd || var=$?`: the \
                        left side of `||` is exempt from errexit, so the status is captured while errexit \
                        stays on for every other command here.
                        """
                    )
                }
            }
        }
    }

    /// The other half of that distinction, pinned separately because it is
    /// the failure mode the `||` idiom exists to avoid: a `set +e` that is
    /// never restored leaves the rest of the block unable to fail loudly.
    @Test("Every `set +e` is restored by a matching `set -e` in the same block")
    func everyErrexitSuspensionIsRestored() throws {
        let files = try Self.workflowFiles()
        #expect(files.contains { $0.lastPathComponent == "ci.yml" })

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for block in runBlocks(in: source) {
                var suspendedAt: Int?
                for line in block.lines {
                    guard let change = Self.errexitChange(in: line.text) else { continue }
                    suspendedAt = change ? nil : (suspendedAt ?? line.number)
                }
                if let suspendedAt {
                    Issue.record(
                        """
                        \(file.lastPathComponent):\(suspendedAt) turns errexit off and never restores it, \
                        so every command below it in this block fails silently. Either restore it with \
                        `set -e` right after the command being inspected, or capture that command's \
                        status with `cmd || var=$?` and leave errexit alone.
                        """
                    )
                }
            }
        }
    }

    /// Every pipeline whose status is captured must keep `pipefail`.
    /// `cmd | tee log` reports *tee's* exit status, which is 0 no matter
    /// what `cmd` did, so without `pipefail` the `|| var=$?` above never
    /// fires and a failing acceptance run reads as a green job — a far
    /// worse outcome than the dead retry this whole file exists for.
    @Test("Every step that captures a piped command's status keeps pipefail on")
    func pipedCaptureKeepsPipefail() throws {
        let files = try Self.workflowFiles()
        #expect(files.contains { $0.lastPathComponent == "ci.yml" })

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for block in runBlocks(in: source) {
                let piped = block.lines.contains { $0.text.contains("| tee ") }
                let captures = block.lines.contains { $0.text.contains("=$?") }
                guard piped, captures else { continue }
                #expect(
                    block.lines.contains { line in
                        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                        return trimmed.hasPrefix("set ") && trimmed.contains("pipefail")
                    },
                    """
                    \(file.lastPathComponent): the `run:` block starting at line \(block.startLine) captures \
                    the status of a command piped into `tee`, but never sets `pipefail`. The pipeline then \
                    reports tee's own exit status, so a failing command reads as success.
                    """
                )
            }
        }
    }

    // MARK: - The rule, executed rather than asserted about

    /// Everything above is a scan over text, which is a CI lint: it can
    /// only ever check that the workflows *say* the right thing, and it
    /// has already been wrong twice about what that is. These run real
    /// `bash` under the exact flags GitHub uses
    /// (`--noprofile --norc -eo pipefail`) and observe what actually
    /// happens, so the premise the whole file rests on is demonstrated
    /// here rather than cited from documentation.
    private func runUnderGitHubShell(_ script: String) throws -> (output: String, status: Int32) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("errexit-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-eo", "pipefail", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    @Test("A bare status read after a failing pipeline is never reached")
    func bareStatusReadAfterFailingPipelineIsDead() throws {
        let result = try runUnderGitHubShell("""
        set -o pipefail
        sh -c 'exit 7' 2>&1 | tee /dev/null
        status=$?
        echo "REACHED:$status"
        """)

        #expect(!result.output.contains("REACHED"), "expected the script to end at the pipeline")
        #expect(result.status == 7)
    }

    @Test("`|| status=$?` captures the failing pipeline's status and keeps going")
    func orCaptureAfterFailingPipelineIsReached() throws {
        let result = try runUnderGitHubShell("""
        set -o pipefail
        status=0
        sh -c 'exit 7' 2>&1 | tee /dev/null || status=$?
        echo "REACHED:$status"
        """)

        #expect(result.output.contains("REACHED:7"))
        #expect(result.status == 0, "the script runs to completion; the captured status is the caller's to act on")
    }

    /// The `unit` job's shape: a background process reaped with `wait`.
    @Test("A bare status read after a failing `wait` is never reached")
    func bareStatusReadAfterFailingWaitIsDead() throws {
        let result = try runUnderGitHubShell("""
        sh -c 'exit 9' &
        test_pid=$!
        wait "$test_pid"
        code=$?
        echo "REACHED:$code"
        """)

        #expect(!result.output.contains("REACHED"), "expected the script to end at `wait`")
        #expect(result.status == 9)
    }

    @Test("`|| code=$?` captures the failing `wait`'s status and keeps going")
    func orCaptureAfterFailingWaitIsReached() throws {
        let result = try runUnderGitHubShell("""
        sh -c 'exit 9' &
        test_pid=$!
        code=0
        wait "$test_pid" || code=$?
        echo "REACHED:$code"
        """)

        #expect(result.output.contains("REACHED:9"))
    }

    /// Why `pipefail` is load-bearing and not decoration: drop it and the
    /// `||` never fires, because `tee` succeeded. The capture then reports
    /// a failing test run as a success — strictly worse than the dead
    /// retry this file exists for, which at least failed the job.
    @Test("Without pipefail the capture reads tee's success, not the command's failure")
    func withoutPipefailTheCaptureReadsSuccess() throws {
        let result = try runUnderGitHubShell("""
        set +o pipefail
        status=0
        sh -c 'exit 7' 2>&1 | tee /dev/null || status=$?
        echo "REACHED:$status"
        """)

        #expect(result.output.contains("REACHED:0"), "this is the failure mode pipefail exists to prevent")
    }

    /// And errexit really is on by default under those flags — the single
    /// fact every rule in this file depends on.
    @Test("GitHub's own shell flags have errexit on")
    func gitHubShellFlagsHaveErrexitOn() throws {
        let result = try runUnderGitHubShell("""
        case "$-" in
          *e*) echo "ERREXIT:on" ;;
          *) echo "ERREXIT:off" ;;
        esac
        """)

        #expect(result.output.contains("ERREXIT:on"))
    }
}
