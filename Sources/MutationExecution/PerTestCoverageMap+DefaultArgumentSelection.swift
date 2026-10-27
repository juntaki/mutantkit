import Foundation
import MutationModel
import SwiftFrontend

public extension PerTestCoverageMap {
    /// The tests a mutant on `point` has to run, or `nil` for "everything".
    ///
    /// A line with no coverage region has no tests attributed to it, which is why `testsCovering`
    /// answers `nil` for it. A literal default argument is the one such line whose effect can still be
    /// bounded: it only matters inside the function it is passed to, so the tests that ran that
    /// function's body are the only ones that can tell the mutant from the original.
    func selection(for point: MutationPoint, originalSource: Data?) -> Set<TestIdentifier>? {
        if let direct = testsCovering(file: point.file, line: point.line) { return direct }
        guard isUnmeasured(file: point.file, line: point.line),
              let originalSource,
              let owner = DefaultArgumentOwner.lineRange(in: originalSource, containing: point.utf8Range)
        else { return nil }
        return testsCovering(file: point.file, lines: owner)
    }
}
