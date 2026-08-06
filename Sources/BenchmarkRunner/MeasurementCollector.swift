import Foundation

/// A directory's real size before and after one tool invocation — never
/// called "bytes written," since this is a directory-size delta
/// (`FileManager` enumeration), not real OS-level I/O byte counting.
/// `positiveGrowthBytes` clamps to `0` rather than underflowing when a
/// tool's own cleanup made the directory shrink (`after < before`).
public struct DiskMeasurement: Codable, Sendable, Equatable {
    public let bytesBefore: UInt64
    public let bytesAfter: UInt64
    public let positiveGrowthBytes: UInt64
    public let finalArtifactBytes: UInt64

    public init(bytesBefore: UInt64, bytesAfter: UInt64) {
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        positiveGrowthBytes = bytesAfter > bytesBefore ? bytesAfter - bytesBefore : 0
        finalArtifactBytes = bytesAfter
    }
}

/// Resource usage sampled for one tool invocation's process tree. Every
/// field is `nil`, never `0`, when the underlying measurement could not be
/// taken — a `0` here would silently claim "measured, and it used nothing,"
/// which is never true for a real build+test run.
public struct ResourceMeasurement: Sendable, Equatable {
    public let peakResidentBytes: UInt64?
    public let cpuTimeSeconds: Double?
    /// Real directory-size delta under the project's own working directory
    /// (includes the tool's own build/derived-data output, since both live
    /// inside it) — `nil` when the before/after sizes could not both be
    /// taken, never a fabricated `0`.
    public let workingDirectoryGrowth: DiskMeasurement?

    public init(peakResidentBytes: UInt64?, cpuTimeSeconds: Double?, workingDirectoryGrowth: DiskMeasurement?) {
        self.peakResidentBytes = peakResidentBytes
        self.cpuTimeSeconds = cpuTimeSeconds
        self.workingDirectoryGrowth = workingDirectoryGrowth
    }

    public static let unavailable = ResourceMeasurement(peakResidentBytes: nil, cpuTimeSeconds: nil, workingDirectoryGrowth: nil)
}

/// Samples `ps` for a process tree's peak RSS/CPU time while a tool
/// invocation runs, and measures directory size deltas for disk usage —
/// best-effort, macOS-specific (`ps`'s column set), and always `nil` rather
/// than guessed when a sample cannot be taken. This never reads Muter's or
/// MutantKit's own internal timing — both tools are opaque external
/// processes to this type, exactly as `ToolRunner` treats them.
public actor MeasurementCollector {
    private var peakResidentBytes: UInt64?
    private var maxCPUTimeSeconds: Double?
    private var samplingTask: Task<Void, Never>?

    public init() {}

    /// Starts polling the process tree rooted at `pid` every `interval`
    /// seconds until `stopSampling()` is called. Call this from
    /// `ToolRunner.run`'s `onProcessStarted` hook — RSS cannot be recovered
    /// once a process has already exited, so sampling must overlap
    /// execution, not follow it.
    public func startSampling(rootProcessID: pid_t, interval: TimeInterval = 0.5) {
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleOnce(rootProcessID: rootProcessID)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// `workingDirectory`/`bytesBefore` are supplied by the caller — this
    /// collector has no notion of "the project's own directory" on its
    /// own, and the "before" size must be captured by the caller ahead of
    /// `tool.prepare`/`tool.run`, since it cannot be recovered afterward.
    public func stopSampling(workingDirectory: URL? = nil, bytesBefore: UInt64? = nil) -> ResourceMeasurement {
        samplingTask?.cancel()
        samplingTask = nil

        var growth: DiskMeasurement?
        if let workingDirectory, let bytesBefore, let bytesAfter = Self.directorySizeBytes(workingDirectory) {
            growth = DiskMeasurement(bytesBefore: bytesBefore, bytesAfter: bytesAfter)
        }

        return ResourceMeasurement(peakResidentBytes: peakResidentBytes, cpuTimeSeconds: maxCPUTimeSeconds, workingDirectoryGrowth: growth)
    }

    private func sampleOnce(rootProcessID: pid_t) async {
        guard let snapshot = Self.runPS() else { return }
        let descendants = Self.processTree(rootedAt: rootProcessID, in: snapshot)
        guard !descendants.isEmpty else { return }

        let totalRSSKilobytes = descendants.reduce(UInt64(0)) { $0 + $1.residentKilobytes }
        let totalCPUSeconds = descendants.reduce(0.0) { $0 + $1.cpuSeconds }

        let totalRSSBytes = totalRSSKilobytes * 1024
        if peakResidentBytes == nil || totalRSSBytes > (peakResidentBytes ?? 0) {
            peakResidentBytes = totalRSSBytes
        }
        if maxCPUTimeSeconds == nil || totalCPUSeconds > (maxCPUTimeSeconds ?? 0) {
            maxCPUTimeSeconds = totalCPUSeconds
        }
    }

    struct ProcessRow {
        let pid: pid_t
        let parentPID: pid_t
        let residentKilobytes: UInt64
        let cpuSeconds: Double
    }

    /// One `ps` snapshot of every process on the system — `pid`, `ppid`,
    /// `rss` (kilobytes), and `time` (parsed from `[[dd-]hh:]mm:ss`).
    static func runPS() -> [ProcessRow]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid=,rss=,time="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parsePS(String(decoding: data, as: UTF8.self))
    }

    static func parsePS(_ output: String) -> [ProcessRow] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]), let rss = UInt64(fields[2])
            else { return nil }
            return ProcessRow(pid: pid, parentPID: ppid, residentKilobytes: rss, cpuSeconds: parseCPUTime(String(fields[3])))
        }
    }

    /// `ps`'s `time=` column: `[[dd-]hh:]mm:ss[.ss]`.
    static func parseCPUTime(_ raw: String) -> Double {
        var dayString = ""
        var rest = raw
        if let dashIndex = raw.firstIndex(of: "-") {
            dayString = String(raw[raw.startIndex ..< dashIndex])
            rest = String(raw[raw.index(after: dashIndex)...])
        }
        let parts = rest.split(separator: ":").map(String.init)
        guard !parts.isEmpty, let seconds = Double(parts.last ?? "") else { return 0 }
        let minutes = parts.count >= 2 ? Double(parts[parts.count - 2]) ?? 0 : 0
        let hours = parts.count >= 3 ? Double(parts[parts.count - 3]) ?? 0 : 0
        let days = Double(dayString) ?? 0
        return days * 86400 + hours * 3600 + minutes * 60 + seconds
    }

    /// BFS over `ppid` links from `root` — every process whose ancestry
    /// traces back to the tool's own root PID, including `root` itself.
    static func processTree(rootedAt root: pid_t, in snapshot: [ProcessRow]) -> [ProcessRow] {
        var byParent: [pid_t: [ProcessRow]] = [:]
        for row in snapshot { byParent[row.parentPID, default: []].append(row) }
        var byPID: [pid_t: ProcessRow] = [:]
        for row in snapshot { byPID[row.pid] = row }

        guard let rootRow = byPID[root] else { return [] }
        var result = [rootRow]
        var queue = [root]
        while let next = queue.popLast() {
            for child in byParent[next] ?? [] {
                result.append(child)
                queue.append(child.pid)
            }
        }
        return result
    }

    /// The total size on disk of every regular file under `url` — used
    /// before/after an invocation to derive a `DiskMeasurement` growth
    /// delta, never an absolute value on its own (a project's own
    /// checked-out source is not "grown" by the tool run on its own).
    public static func directorySizeBytes(_ url: URL) -> UInt64? {
        // `FileManager.enumerator(at:)` does not fail at creation for a
        // path that doesn't exist — it lazily yields nothing when
        // iterated, which would silently read as "0 bytes," not
        // "unmeasurable." Checked explicitly so a missing directory stays
        // `nil`, never a fabricated `0`.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }

        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize
            else { continue }
            total += UInt64(size)
        }
        return total
    }
}
