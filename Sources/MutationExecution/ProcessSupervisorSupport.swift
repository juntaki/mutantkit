import Foundation

// MARK: - Support types for ProcessSupervisor

/// Accumulates pipe output from a drain thread.
final class DataBox: @unchecked Sendable {
    private var storage = Data()
    /// Set only when this stream's drain loop observed real EOF
    /// (`read() == 0`) — never on a `read()` error. See `drain`'s own
    /// comments and `ProcessResult.outputComplete`'s doc comment for why
    /// the two must stay distinguishable.
    private var eofReached = false
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func markEOF() {
        lock.lock()
        eofReached = true
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var reachedEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eofReached
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
