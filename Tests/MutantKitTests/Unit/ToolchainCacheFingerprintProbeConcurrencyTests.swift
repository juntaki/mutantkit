import Foundation
@testable import MutationExecution
import Testing

@Suite("ToolchainCacheFingerprintProbe: concurrent first callers")
struct ToolchainCacheFingerprintProbeConcurrencyTests {
    private actor ProbeCounter {
        private(set) var calls = 0
        func next() -> Int {
            calls += 1
            return calls
        }
    }

    /// An untrustworthy probe resolves to a fresh random value on every run, so two probes that
    /// both run give two different cache directories. Every caller must see the one that was kept.
    @Test("Callers that arrive together share one probe run and one value")
    func concurrentCallersShareOneValue() async {
        let counter = ProbeCounter()
        let probe = ToolchainCacheFingerprintProbe { _ in
            let call = await counter.next()
            try? await Task.sleep(for: .milliseconds(50))
            return SharedModuleCacheFingerprint(
                swiftVersion: "unknown-untrustworthy-\(call)-\(UUID().uuidString)", xcodeVersion: "x", sdkVersion: "s", targetTriple: "t"
            )
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())

        let values = await withTaskGroup(of: SharedModuleCacheFingerprint.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await probe.fingerprint(workingDirectory: directory) }
            }
            return await group.reduce(into: [SharedModuleCacheFingerprint]()) { $0.append($1) }
        }

        #expect(Set(values).count == 1)
        #expect(await counter.calls == 1)
        #expect(await probe.fingerprint(workingDirectory: directory) == values.first)
    }
}
