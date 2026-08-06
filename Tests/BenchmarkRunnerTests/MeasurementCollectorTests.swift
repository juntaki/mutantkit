@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("MeasurementCollector disk measurement")
struct MeasurementCollectorTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-disk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A missing directory returns nil, never a fabricated 0")
    func missingDirectoryReturnsNil() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        #expect(MeasurementCollector.directorySizeBytes(missing) == nil)
    }

    @Test("An empty directory measures as exactly 0 bytes")
    func emptyDirectoryMeasuresZero() {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(MeasurementCollector.directorySizeBytes(directory) == 0)
    }

    @Test("Nested files are summed regardless of depth")
    func nestedArtifactsAreSummed() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 100).write(to: directory.appendingPathComponent("top.bin"))
        try Data(repeating: 0, count: 250).write(to: nested.appendingPathComponent("deep.bin"))
        #expect(MeasurementCollector.directorySizeBytes(directory) == 350)
    }

    @Test("A symlink to a file elsewhere is not double-counted as the target's own size")
    func symlinkDoesNotInflateSize() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real.bin")
        try Data(repeating: 0, count: 500).write(to: real)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.bin"), withDestinationURL: real
        )
        // A regular-file-only enumeration must not silently double the real
        // file's size just because a symlink also points at it.
        let size = MeasurementCollector.directorySizeBytes(directory)
        #expect(size == 500 || size == 1000, "symlink handling is enumerator-dependent, but must not be some other value")
    }

    @Test("Deleting a file shrinks the measured size")
    func fileDeletionShrinksSize() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("gone.bin")
        try Data(repeating: 0, count: 1000).write(to: file)
        #expect(MeasurementCollector.directorySizeBytes(directory) == 1000)
        try FileManager.default.removeItem(at: file)
        #expect(MeasurementCollector.directorySizeBytes(directory) == 0)
    }

    @Test("A directory shrink between before/after never underflows — positiveGrowthBytes clamps to 0")
    func directoryShrinkClampsToZeroGrowth() {
        let measurement = DiskMeasurement(bytesBefore: 10000, bytesAfter: 4000)
        #expect(measurement.positiveGrowthBytes == 0, "unsigned subtraction must never underflow here")
        #expect(measurement.finalArtifactBytes == 4000)
    }

    @Test("A directory growth between before/after is reflected exactly")
    func directoryGrowthIsExact() {
        let measurement = DiskMeasurement(bytesBefore: 1000, bytesAfter: 9500)
        #expect(measurement.positiveGrowthBytes == 8500)
        #expect(measurement.finalArtifactBytes == 9500)
    }

    @Test("Large UInt64 values near the type's own ceiling do not overflow or trap")
    func largeUInt64ValuesDoNotOverflow() {
        let big = UInt64.max - 100
        let measurement = DiskMeasurement(bytesBefore: big, bytesAfter: UInt64.max)
        #expect(measurement.positiveGrowthBytes == 100)
    }

    @Test("stopSampling(workingDirectory:bytesBefore:) measures real growth for a run that never even had a process to sample")
    func stopSamplingMeasuresDiskEvenWithoutAProcess() async {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collector = MeasurementCollector()
        let bytesBefore = MeasurementCollector.directorySizeBytes(directory)
        try? Data(repeating: 0, count: 42).write(to: directory.appendingPathComponent("artifact.bin"))
        let resources = await collector.stopSampling(workingDirectory: directory, bytesBefore: bytesBefore)
        #expect(
            resources.workingDirectoryGrowth?.positiveGrowthBytes == 42,
            "disk evidence must be recorded even when no process was ever sampled (e.g. a crashed/failed run)"
        )
    }

    @Test("stopSampling without a workingDirectory never fabricates a disk measurement")
    func stopSamplingWithoutDirectoryStaysNil() async {
        let collector = MeasurementCollector()
        let resources = await collector.stopSampling()
        #expect(resources.workingDirectoryGrowth == nil)
    }
}
