import Foundation

// MARK: - Support types for ProcessSupervisor

/// Owns one pipe read end for its whole life: reads on a global-queue task,
/// bounded in memory, stoppable, and closes the descriptor itself on the
/// reading thread — no other thread ever closes it, so there is no fd-reuse
/// race. The reader waits in `poll` slices, never in a blocking `read`, so
/// `stop()` ends it within one slice even while a leaked writer holds the
/// pipe open, and nothing is appended after the owner has taken `value`.
final class PipeDrain: @unchecked Sendable {
    /// Per-stream capture ceiling when the caller does not choose one.
    static let defaultMaxBytes = 256 * 1024 * 1024
    static let pollSliceMilliseconds: Int32 = 50

    private let lock = NSLock()
    private var storage = Data()
    private var eofReached = false
    private var truncatedFlag = false
    private var stopRequested = false
    private let maxBytes: Int
    private let readFD: Int32

    /// Starts reading `fd` (taking ownership of it) and enters `group` until
    /// the reader has closed it.
    init(fd: Int32, maxBytes: Int = PipeDrain.defaultMaxBytes, group: DispatchGroup) {
        readFD = fd
        self.maxBytes = maxBytes
        // A dedicated thread, not a global-queue task: a reader that is merely
        // slow to be scheduled must not look like a leaked descriptor, and
        // blocking in `poll` must not occupy a shared pool thread.
        group.enter()
        let thread = Thread { [self] in
            run()
            close(readFD)
            group.leave()
        }
        thread.stackSize = 256 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Asks the reader to finish; it closes the fd and leaves its group
    /// within one poll slice.
    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !shouldStop {
            var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Self.pollSliceMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
            switch ProcessSupervisor.classify(readResult: count, errno: errno) {
            case .data: append(buffer[0 ..< count])
            case .eof:
                lock.lock()
                eofReached = true
                lock.unlock()
                return
            case .retry: continue
            case .error: return
            }
        }
    }

    private func append(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        defer { lock.unlock() }
        let room = max(0, maxBytes - storage.count)
        if bytes.count > room { truncatedFlag = true }
        storage.append(contentsOf: bytes.prefix(room))
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Only genuine EOF (`read() == 0`) proves the writer finished; a read
    /// error or a stop does not.
    var reachedEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eofReached
    }

    /// Bytes beyond `maxBytes` were read and discarded: the capture is
    /// incomplete evidence however the stream ended.
    var truncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncatedFlag
    }
}

/// Holds a NULL-terminated `char *[]` alive for the duration of a spawn.
///
/// The buffer is heap-allocated rather than bridged from a Swift `Array`:
/// taking a pointer to an array's storage yields one valid only for that
/// expression, and `posix_spawn` needs it to survive the whole call.
final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let capacity: Int

    init(_ strings: [String]) {
        capacity = strings.count + 1
        pointers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: capacity)
        for (index, string) in strings.enumerated() {
            pointers[index] = strdup(string)
        }
        pointers[strings.count] = nil
    }

    deinit {
        for index in 0 ..< (capacity - 1) {
            free(pointers[index])
        }
        pointers.deallocate()
    }
}
