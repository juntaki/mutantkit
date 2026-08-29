import Darwin
@testable import MutationExecution
import Testing

/// Direct, timing-free regression for the exact distinction
/// `ProcessResult.outputComplete` depends on: `drain`'s loop exits on
/// either a real EOF (`read() == 0`) or a genuine read error
/// (`read() < 0 && errno != EINTR`), and only the former is proof the bytes
/// captured so far are the whole story. `ProcessSupervisorOutputCompletenessTests`
/// (`ForcedIncompleteOutputFixture`) proves the EOF/timeout side against a
/// real subprocess; it cannot force a genuine `read()` error on a real pipe
/// at all (they are rare and not reproducible on demand), which is exactly
/// why `ProcessSupervisor.classify(readResult:errno:)` was split out of the
/// loop as a pure function — this suite exercises the one branch no real-fd
/// fixture can reach.
@Suite("ProcessSupervisor: drain read-result classification")
struct ProcessSupervisorDrainClassificationTests {
    @Test("A positive count classifies as .data, carrying the byte count")
    func positiveCountIsData() {
        #expect(ProcessSupervisor.classify(readResult: 42, errno: 0) == .data(42))
    }

    @Test("A zero count (real EOF) classifies as .eof, regardless of whatever errno happens to be set to")
    func zeroCountIsEOF() {
        #expect(ProcessSupervisor.classify(readResult: 0, errno: 0) == .eof)
        // `errno` is only meaningful when the syscall itself reported
        // failure; a stale value from a previous, unrelated call must not
        // change a genuine EOF's classification.
        #expect(ProcessSupervisor.classify(readResult: 0, errno: EINTR) == .eof)
    }

    @Test("A negative count with errno == EINTR classifies as .retry, never .eof and never .error")
    func negativeCountWithEINTRIsRetry() {
        #expect(ProcessSupervisor.classify(readResult: -1, errno: EINTR) == .retry)
    }

    /// The actual regression: a genuine read failure must classify as
    /// `.error`, not `.eof` — `.eof` is the one outcome `drain` treats as
    /// proof of completeness (`DataBox.markEOF()`), so misclassifying this
    /// as `.eof` is exactly the bug `outputComplete`'s own doc comment
    /// warns against: reporting evidence as complete when it is not.
    @Test("A negative count with a real error errno (not EINTR) classifies as .error, never .eof")
    func negativeCountWithARealErrorIsError() {
        #expect(ProcessSupervisor.classify(readResult: -1, errno: EIO) == .error)
        #expect(ProcessSupervisor.classify(readResult: -1, errno: EBADF) == .error)
        #expect(ProcessSupervisor.classify(readResult: -1, errno: 0) == .error)
    }
}
