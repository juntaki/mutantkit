/// Every way the SwiftPM path refuses to map a compilation unit's target to
/// a real built image — fail-closed: an ambiguous or unproven mapping must
/// never be resolved by guessing.
public enum SwiftPMImageResolutionError: Error, CustomStringConvertible, Equatable {
    /// No test target in the dependency graph transitively depends on this
    /// target — its code was never linked into anything actually tested,
    /// so no image could ever be proven to contain it.
    case targetUnreachableFromAnyTestTarget(String)
    /// More than one built image was discovered, and none of them exactly
    /// matches a declared SwiftPM product containing this target — the
    /// common (single combined test bundle) case does not need this at
    /// all; this only triggers for a genuinely ambiguous multi-image build
    /// this resolver refuses to guess through.
    case ambiguousImageForTarget(String)
    /// Several test targets depend on this target, so the code is linked into
    /// several images; at least one of those test targets has no discovered
    /// image with exactly its name (or more than one). Accepting the images
    /// found would claim a containing set the build did not prove.
    case unprovenImageForDependentTestTarget(target: String, testTarget: String)

    public var description: String {
        switch self {
        case let .targetUnreachableFromAnyTestTarget(target):
            "target \(target) is not a dependency of any test target, so no built image could ever contain its code"
        case let .ambiguousImageForTarget(target):
            "more than one built image was discovered and none exactly matches a declared product containing target \(target)"
        case let .unprovenImageForDependentTestTarget(target, testTarget):
            "target \(target) is linked into test target \(testTarget), but exactly one built image named \(testTarget) was not found"
        }
    }
}

/// Maps a SwiftPM compilation unit's real target identity to the real
/// built image its code ends up in — by dependency-graph reachability
/// proven from `swift package describe`, never by matching a discovered
/// bundle's filename against the target's name.
///
/// The key fact this relies on: modern SwiftPM (`swift build --build-tests`)
/// links every local test target's own dependency closure into one
/// combined `<Package>PackageTests.xctest` bundle — confirmed against a
/// real build, not assumed. So for the ordinary case (exactly one
/// discovered image), any target reachable from at least one test target
/// is proven, by SwiftPM's own static-linking model, to be inside that one
/// image — no name comparison needed at all. A build producing more than
/// one image (a declared library/executable product built alongside the
/// test bundle) is disambiguated by exact product-name equality against
/// `swift package describe`'s own `products` list, never a substring
/// guess.
public enum SwiftPMCompilationUnitImageResolver {
    /// Every image proven to contain each target's code. One element for the
    /// combined-bundle and declared-product cases; one per dependent test
    /// target for Xcode 27's one-`.xctest`-per-test-target builds (the multi-image build receipt).
    ///
    /// `productImages` are the built images of executable and dynamic-library
    /// products (by product name). A target is also contained in each of those
    /// whose product depends on it, because a test can launch such an image as
    /// a child process and the mutation then runs there, not in the test
    /// bundle. An image whose product does not depend on the target is ignored.
    public static func resolve(
        targets: Set<String>, graph: SwiftPMDependencyGraph, discovered: [DiscoveredImage],
        productImages: [String: DiscoveredImage] = [:]
    ) throws -> [String: [DiscoveredImage]] {
        var resolved: [String: [DiscoveredImage]] = [:]
        for target in targets {
            var images = try resolveOne(target: target, graph: graph, discovered: discovered)
            for product in graph.finalImageProducts(containing: target) {
                guard let image = productImages[product.name],
                      !images.contains(where: { $0.binaryPath == image.binaryPath })
                else { continue }
                images.append(image)
            }
            resolved[target] = images
        }
        return resolved
    }

    private static func resolveOne(
        target: String, graph: SwiftPMDependencyGraph, discovered: [DiscoveredImage]
    ) throws -> [DiscoveredImage] {
        let dependents = graph.transitiveDependents(of: target)
        let dependentTestTargets = dependents.filter { graph.isTestTarget($0) }.sorted()
        guard !dependentTestTargets.isEmpty else {
            throw SwiftPMImageResolutionError.targetUnreachableFromAnyTestTarget(target)
        }

        if discovered.count == 1 {
            // Proven by SwiftPM's own static-linking model: the target is
            // reachable from a real test target, and there is exactly one
            // built test image for this workspace to have landed in.
            return [discovered[0]]
        }

        // More than one image. First, an exact product-name match, never a
        // substring guess, resolves a declared library/executable product.
        let matchingProducts = graph.products.filter { _, members in members.contains(target) }
        let productCandidates = discovered.filter { image in matchingProducts.keys.contains(image.bundleName) }
        if productCandidates.count == 1, let candidate = productCandidates.first {
            return [candidate]
        }

        // Otherwise the code is linked into one bundle per dependent test
        // target (Xcode 27 / Swift 6.4). Each dependent test target must match
        // exactly one discovered image by exact name; if any does not, the
        // containing set is unproven and the whole target fails closed.
        // (Several product-named images claiming the same target stay ambiguous.)
        guard productCandidates.isEmpty else { throw SwiftPMImageResolutionError.ambiguousImageForTarget(target) }
        return try dependentTestTargets.map { testTarget in
            let matches = discovered.filter { $0.bundleName == testTarget }
            guard matches.count == 1, let image = matches.first else {
                throw SwiftPMImageResolutionError.unprovenImageForDependentTestTarget(target: target, testTarget: testTarget)
            }
            return image
        }
    }
}
