import Foundation

/// Deliberately outside `UnlinkedSource`'s Compile Sources — present on disk
/// and matched by `sources.include`, but never fed to the compiler. See
/// `project.yml` for how the target's `sources:` excludes this directory.
enum Unused {
    static func isOverLimit(count: Int) -> Bool {
        count > 10
    }
}
