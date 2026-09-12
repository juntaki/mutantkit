import Foundation
import MuterCompatibility

/// Exercises Muter's YAML-first, JSON-fallback configuration importer with
/// arbitrary bytes. Invalid input is expected; crashes and sanitizer failures
/// are not.
@_cdecl("LLVMFuzzerTestOneInput")
public func LLVMFuzzerTestOneInput(
    _ bytes: UnsafePointer<UInt8>,
    _ count: Int
) -> Int32 {
    let data = Data(bytes: bytes, count: count)
    _ = try? MuterConfigImporter().importConfiguration(
        from: data,
        sourceName: "fuzz-input"
    )
    return 0
}
