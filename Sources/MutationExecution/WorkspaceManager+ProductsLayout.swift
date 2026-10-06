import Foundation

extension WorkspaceManager {
    /// Where a nested products clone puts the products under `destination`.
    ///
    /// When `productsDirectory` is SwiftPM's `debug` symlink, the answer is
    /// the resolved directory's path relative to the scratch directory that
    /// holds the symlink, whatever shape SwiftPM gave it. Otherwise (a real
    /// directory, so no scratch directory can be derived) it falls back to
    /// the last two path components, the classic `<triple>/<configuration>`.
    nonisolated static func nestedProductsDestination(
        under destination: URL, productsDirectory: URL, resolved: URL
    ) -> URL {
        let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: productsDirectory.path)) != nil
        let scratch = productsDirectory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let products = resolved.standardizedFileURL
        let prefix = scratch.path.hasSuffix("/") ? scratch.path : scratch.path + "/"
        let components: [String]
        if isSymlink, products.path.hasPrefix(prefix), products.path.count > prefix.count {
            components = String(products.path.dropFirst(prefix.count))
                .split(separator: "/").map(String.init)
        } else {
            components = [products.deletingLastPathComponent().lastPathComponent, products.lastPathComponent]
        }
        return components.reduce(destination) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}
