import Foundation

/// The one place that answers "which `.xcworkspace` / `.xcodeproj` does this
/// directory mean".
///
/// Detection, explicit-kind classification and target resolution used to each
/// take the first entry of an unsorted directory listing, so two of them could
/// disagree about which container a run was. A directory with two candidates of
/// the same kind has no unambiguous answer, and an unreadable directory is not
/// the same thing as an empty one; both are reported, never guessed.
public enum ProjectContainerLocator {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unreadableDirectory(path: String, underlying: String)
        case ambiguous(pathExtension: String, directory: String, candidates: [String])

        public var description: String {
            switch self {
            case let .unreadableDirectory(path, underlying):
                "Could not list \(path) to look for an Xcode project: \(underlying)"
            case let .ambiguous(pathExtension, directory, candidates):
                """
                \(directory) holds more than one .\(pathExtension) (\(candidates.joined(separator: ", "))), so \
                which one to build is ambiguous. Keep only the intended one in the project root.
                """
            }
        }
    }

    /// The single entry directly inside `directory` with `pathExtension`, or
    /// `nil` when there is none.
    public static func locate(pathExtension: String, in directory: URL) throws -> URL? {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw Failure.unreadableDirectory(path: directory.path, underlying: "\(error)")
        }
        // Only real containers: a plain file or an AppleDouble `._` shadow of one
        // is not a candidate.
        let matches = contents.filter {
            $0.pathExtension == pathExtension && !$0.lastPathComponent.hasPrefix("._")
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard matches.count <= 1 else {
            throw Failure.ambiguous(
                pathExtension: pathExtension, directory: directory.path, candidates: matches.map(\.lastPathComponent)
            )
        }
        return matches.first
    }

    public static func workspace(in directory: URL) throws -> URL? {
        try locate(pathExtension: "xcworkspace", in: directory)
    }

    public static func project(in directory: URL) throws -> URL? {
        try locate(pathExtension: "xcodeproj", in: directory)
    }
}
