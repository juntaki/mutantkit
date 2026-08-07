import Foundation

extension Acceptance {
    /// Wave-specific acceptance is deliberately a second opt-in beyond the
    /// ordinary simulator suites. This validation branch is based on `main`,
    /// where wave execution does not exist yet; the suite is enabled only when
    /// this branch is tested together with the implementation branch.
    static var waveEnabled: Bool {
        simulatorEnabled && ProcessInfo.processInfo.environment["MUTANTKIT_WAVE_ACCEPTANCE"] == "1"
    }
}
