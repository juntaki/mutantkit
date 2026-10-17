@testable import AppleBuildAdapters
import Foundation
@testable import MutationModel
import Testing

// The multi-image build receipt: a compilation unit may be contained in several built images (Xcode 27 builds one
// `.xctest` per SwiftPM test target, each statically linking the library under test).

private func uuid(_ byte: UInt8) -> ImageUUID {
    ImageUUID(rawValue: String(repeating: String(format: "%02x", byte), count: 16))!
}

private let libraryTarget = BuildTargetIdentity(projectIdentity: "proj", targetName: "Library", moduleName: "Library")

private func image(_ path: String, _ byte: UInt8, owner: BuildTargetIdentity? = nil) throws -> BuiltImageReceipt {
    try BuiltImageReceipt(
        ownerBuildTarget: owner, binaryPath: path, contentHash: SHA256Digest.of(path),
        slices: [BuiltImageSlice(architecture: BuiltArchitectureIdentity(cpuType: 0x0100_000C, cpuSubtype: 0), imageUUID: uuid(byte))]
    )
}

private func unit(containing ids: [BuiltImageID]) -> CompilationUnitReceipt {
    CompilationUnitReceipt(
        compilationUnitID: schemataFixtureCompilationUnitID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
        sourceBuildTarget: libraryTarget, containingImageIDs: ids
    )
}

private func receipt(images: [BuiltImageReceipt], units: [CompilationUnitReceipt]) throws -> SchemataBuildReceipt {
    try SchemataBuildReceipt(
        planID: "plan-1", workUnitID: "wu-1", chunkID: "chunk-1", toolchainHash: SHA256Digest.of("toolchain"),
        buildArgumentsHash: SHA256Digest.of("args"), runtimeABIVersion: 3, images: images, compilationUnits: units
    )
}

@Suite("Schemata build receipt v3: one compilation unit, N images")
struct SchemataMultiImageReceiptTests {
    @Test("a unit can name several containing images, and the receipt resolves all of them")
    func unitWithTwoImages() throws {
        let a = try image("/b/TestsA.xctest/TestsA", 0x01)
        let b = try image("/b/TestsB.xctest/TestsB", 0x02)
        let built = try receipt(images: [a, b], units: [unit(containing: [a.imageID, b.imageID])])
        let resolved = built.images(containing: built.compilationUnits[0])
        #expect(Set(resolved.map(\.imageID)) == [a.imageID, b.imageID])
        #expect(built.version == 3)
    }

    @Test("image identity is derived from path, hash and slices, and differs between images")
    func imageIDIsDerived() throws {
        let a1 = try image("/b/A", 0x01)
        let a2 = try image("/b/A", 0x01)
        let b = try image("/b/B", 0x01)
        #expect(a1.imageID == a2.imageID)
        #expect(a1.imageID != b.imageID)
    }

    @Test("a unit naming an image that is not in the receipt is refused")
    func unknownContainingImageIsRefused() throws {
        let a = try image("/b/A", 0x01)
        let ghost = try image("/b/Ghost", 0x09)
        #expect(throws: SchemataBuildReceiptError.unknownContainingImage(schemataFixtureCompilationUnitID, ghost.imageID)) {
            _ = try receipt(images: [a], units: [unit(containing: [a.imageID, ghost.imageID])])
        }
    }

    @Test("a unit listing the same containing image twice is refused")
    func duplicateContainingImageIsRefused() throws {
        let a = try image("/b/A", 0x01)
        #expect(throws: SchemataBuildReceiptError.duplicateContainingImage(schemataFixtureCompilationUnitID, a.imageID)) {
            _ = try receipt(images: [a], units: [unit(containing: [a.imageID, a.imageID])])
        }
    }

    @Test("two images reporting the same ImageUUID are refused")
    func sharedImageUUIDIsRefused() throws {
        let a = try image("/b/A", 0x01)
        let b = try image("/b/B", 0x01)
        #expect(throws: SchemataBuildReceiptError.imageUUIDSharedAcrossImages(uuid(0x01))) {
            _ = try receipt(images: [a, b], units: [])
        }
    }

    @Test("the same image reported twice is refused")
    func duplicateImageIDIsRefused() throws {
        let a = try image("/b/A", 0x01)
        #expect(throws: SchemataBuildReceiptError.duplicateImageID(a.imageID)) {
            _ = try receipt(images: [a, a], units: [])
        }
    }

    @Test("a v3 receipt round-trips through JSON")
    func v3RoundTrips() throws {
        let a = try image("/b/A", 0x01)
        let b = try image("/b/B", 0x02)
        let built = try receipt(images: [a, b], units: [unit(containing: [a.imageID, b.imageID])])
        let decoded = try JSONDecoder().decode(SchemataBuildReceipt.self, from: JSONEncoder().encode(built))
        #expect(decoded == built)
    }

    @Test("a v2 receipt (one buildTarget per unit and image) still decodes, normalized to v3")
    func v2IsNormalized() throws {
        let v2 = """
        {"version":2,"planID":"p","workUnitID":"w","chunkID":"c",
         "toolchainHash":"\(SHA256Digest.of("t").rawValue)","buildArgumentsHash":"\(SHA256Digest.of("a").rawValue)",
         "runtimeABIVersion":3,
         "images":[{"buildTarget":{"projectIdentity":"proj","targetName":"Library","moduleName":"Library"},
                    "binaryPath":"/b/Lib","contentHash":"\(SHA256Digest.of("x").rawValue)",
                    "slices":[{"architecture":{"cpuType":16777228,"cpuSubtype":0},"imageUUID":"\(uuid(0x07).rawValue)"}]}],
         "compilationUnits":[{"compilationUnitID":"\(schemataFixtureCompilationUnitID.rawValue)",
                              "sourceEmbeddingID":"\(schemataFixtureSourceEmbeddingID.rawValue)",
                              "buildTarget":{"projectIdentity":"proj","targetName":"Library","moduleName":"Library"}}]}
        """
        let decoded = try JSONDecoder().decode(SchemataBuildReceipt.self, from: Data(v2.utf8))
        #expect(decoded.version == 3)
        #expect(decoded.images.count == 1)
        #expect(decoded.compilationUnits[0].containingImageIDs == [decoded.images[0].imageID])
    }

    @Test("a stored imageID that does not match the image's own bytes is rejected on decode")
    func tamperedImageIDIsRejected() throws {
        let a = try image("/b/A", 0x01)
        var json = try #require(String(data: JSONEncoder().encode(a), encoding: .utf8))
        json = json.replacingOccurrences(of: a.imageID.rawValue.rawValue, with: SHA256Digest.of("forged").rawValue)
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(BuiltImageReceipt.self, from: Data(json.utf8)) }
    }
}

@Suite("Schemata chain verification with a unit contained in several images")
struct SchemataMultiImageVerifierTests {
    private func observation(
        containing images: [BuiltImageReceipt], started: [(pid: Int32, image: ImageUUID)], hits: [(pid: Int32, image: ImageUUID)]
    ) throws -> SchemataExecutionObservation {
        let built = try receipt(images: images, units: [unit(containing: images.map(\.imageID))])
        var records: [RuntimeEventRecord] = started.map {
            .startup(RuntimeStartupEvent(
                runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
                compilationUnitID: schemataFixtureCompilationUnitID,
                token: schemataFixtureToken, processID: $0.pid, imageUUID: $0.image, runtimeABIVersion: 3
            ))
        }
        records += hits.map {
            .hit(RuntimeHitEvent(
                runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
                compilationUnitID: schemataFixtureCompilationUnitID,
                token: schemataFixtureToken, processID: $0.pid, sequence: 1, imageUUID: $0.image, runtimeABIVersion: 3
            ))
        }
        return SchemataExecutionObservation(
            expectation: makeSchemataExpectation(), buildReceipt: built, transcript: RuntimeTranscript(protocolVersion: 3, records: records)
        )
    }

    private func outcome(of observation: SchemataExecutionObservation) throws -> MutationOutcome {
        let point = try makeAnchoredPoint()
        let ref = PlannedMutationRef.forPoint(point, planID: "plan-A", workUnitID: "unit-1")
        let run = TestRunResult(
            status: .passed, summary: nil, command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "ok", isBatchAttributedTimeout: false
        )
        let record = MutationVerdictVerifier.verify(
            MutationObservations(
                plannedMutation: ref,
                sourceApplication: .applied(makeEvidence(buildProductHash: "h1", applicationEvidence: .schemata(observation))),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                coverage: nil,
                test: SingleTestObservation(run: run, applicationEvidence: .schemata(observation), execution: wholeSuiteExecution)
            ),
            policy: .permissive
        )
        return record.outcome
    }

    @Test("only one of the containing images ran: its complete STARTUP -> HIT is sufficient")
    func oneImageRanIsEnough() throws {
        let a = try image("/b/A", 0x01), b = try image("/b/B", 0x02)
        let obs = try observation(containing: [a, b], started: [(100, uuid(0x02))], hits: [(100, uuid(0x02))])
        #expect(try outcome(of: obs) == .survived)
    }

    @Test("both images in one process, each with its own STARTUP and HIT, verifies (key is process + image)")
    func twoImagesInOneProcess() throws {
        let a = try image("/b/A", 0x01), b = try image("/b/B", 0x02)
        let obs = try observation(
            containing: [a, b], started: [(100, uuid(0x01)), (100, uuid(0x02))], hits: [(100, uuid(0x01)), (100, uuid(0x02))]
        )
        #expect(try outcome(of: obs) == .survived)
    }

    @Test("two STARTUPs for the same process and the same image is still a violation")
    func duplicateStartupSameImage() throws {
        let a = try image("/b/A", 0x01), b = try image("/b/B", 0x02)
        let obs = try observation(containing: [a, b], started: [(100, uuid(0x01)), (100, uuid(0x01))], hits: [(100, uuid(0x01))])
        #expect(try outcome(of: obs) == .infrastructureFailure)
    }

    @Test("a HIT from an image outside the unit's containing set never verifies")
    func hitFromForeignImage() throws {
        let a = try image("/b/A", 0x01), outsider = try image("/b/Out", 0x09)
        let built = try receipt(images: [a, outsider], units: [unit(containing: [a.imageID])])
        let obs = SchemataExecutionObservation(
            expectation: makeSchemataExpectation(), buildReceipt: built,
            transcript: RuntimeTranscript(protocolVersion: 3, records: [
                .startup(RuntimeStartupEvent(
                    runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
                    compilationUnitID: schemataFixtureCompilationUnitID, token: schemataFixtureToken, processID: 100,
                    imageUUID: uuid(0x09), runtimeABIVersion: 3
                )),
                .hit(RuntimeHitEvent(
                    runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
                    compilationUnitID: schemataFixtureCompilationUnitID, token: schemataFixtureToken, processID: 100, sequence: 1,
                    imageUUID: uuid(0x09), runtimeABIVersion: 3
                ))
            ])
        )
        #expect(try outcome(of: obs) == .infrastructureFailure)
    }

    @Test("a unit with no proven containing image does not verify")
    func unitWithoutImage() throws {
        let a = try image("/b/A", 0x01)
        let built = try receipt(images: [a], units: [unit(containing: [])])
        let obs = SchemataExecutionObservation(
            expectation: makeSchemataExpectation(), buildReceipt: built,
            transcript: RuntimeTranscript(protocolVersion: 3, records: [])
        )
        #expect(try outcome(of: obs) == .infrastructureFailure)
    }
}

@Suite("SwiftPM image resolver: images per target")
struct SwiftPMMultiImageResolverTests {
    private func graph(testTargets: [String], products: [String: Set<String>] = [:]) -> SwiftPMDependencyGraph {
        var targets: [String: SwiftPMDependencyGraph.TargetInfo] = [
            "Library": .init(name: "Library", type: "library", path: "Sources/Library", sources: [], dependencies: [])
        ]
        for name in testTargets {
            targets[name] = .init(name: name, type: "test", path: "Tests/\(name)", sources: [], dependencies: ["Library"])
        }
        return SwiftPMDependencyGraph(projectIdentity: "proj", targets: targets, products: products)
    }

    private func discovered(_ names: [String]) throws -> [DiscoveredImage] {
        try names.enumerated().map { index, name in
            let built = try image("/b/\(name).xctest/\(name)", UInt8(index + 1))
            return DiscoveredImage(bundleName: name, binaryPath: built.binaryPath, contentHash: built.contentHash, slices: built.slices)
        }
    }

    @Test("one combined bundle still resolves to that single image")
    func singleImage() throws {
        let found = try discovered(["PackageTests"])
        let resolved = try SwiftPMCompilationUnitImageResolver.resolve(
            targets: ["Library"], graph: graph(testTargets: ["TestsA", "TestsB"]), discovered: found
        )
        #expect(resolved["Library"]?.map(\.bundleName) == ["PackageTests"])
    }

    @Test("one bundle per dependent test target resolves to every one of them, by exact name")
    func oneImagePerTestTarget() throws {
        let found = try discovered(["TestsA", "TestsB"])
        let resolved = try SwiftPMCompilationUnitImageResolver.resolve(
            targets: ["Library"], graph: graph(testTargets: ["TestsA", "TestsB"]), discovered: found
        )
        #expect(Set(resolved["Library"]?.map(\.bundleName) ?? []) == ["TestsA", "TestsB"])
    }

    @Test("a dependent test target with no matching image fails closed instead of accepting the images found")
    func missingImageFailsClosed() throws {
        let found = try discovered(["TestsA", "Unrelated"])
        #expect(throws: SwiftPMImageResolutionError.unprovenImageForDependentTestTarget(target: "Library", testTarget: "TestsB")) {
            _ = try SwiftPMCompilationUnitImageResolver.resolve(
                targets: ["Library"], graph: graph(testTargets: ["TestsA", "TestsB"]), discovered: found
            )
        }
    }

    @Test("a declared product named like one bundle still takes precedence")
    func productNameMatchStillWins() throws {
        let found = try discovered(["Library", "TestsA"])
        let resolved = try SwiftPMCompilationUnitImageResolver.resolve(
            targets: ["Library"], graph: graph(testTargets: ["TestsA", "TestsB"], products: ["Library": ["Library"]]), discovered: found
        )
        #expect(resolved["Library"]?.map(\.bundleName) == ["Library"])
    }
}

@Suite("SwiftPM final-image products: executables and dynamic libraries")
struct SwiftPMFinalImageProductTests {
    /// Library <- Tool (executable, depends on Library); Unrelated (executable, no dependency); Tests -> Library.
    private func graph() -> SwiftPMDependencyGraph {
        let targets: [String: SwiftPMDependencyGraph.TargetInfo] = [
            "Library": .init(name: "Library", type: "library", path: "Sources/Library", sources: [], dependencies: []),
            "Middle": .init(name: "Middle", type: "library", path: "Sources/Middle", sources: [], dependencies: ["Library"]),
            "Tool": .init(name: "Tool", type: "executable", path: "Sources/Tool", sources: [], dependencies: ["Middle"]),
            "Unrelated": .init(name: "Unrelated", type: "executable", path: "Sources/Unrelated", sources: [], dependencies: []),
            "Tests": .init(name: "Tests", type: "test", path: "Tests/Tests", sources: [], dependencies: ["Library"])
        ]
        return SwiftPMDependencyGraph(
            projectIdentity: "proj", targets: targets,
            products: ["tool": ["Tool"], "unrelated": ["Unrelated"], "LibDyn": ["Library"], "LibStatic": ["Library"]],
            productKinds: ["tool": .executable, "unrelated": .executable, "LibDyn": .dynamicLibrary, "LibStatic": .other]
        )
    }

    @Test("an executable is a containing product through its transitive target closure; an independent one is not")
    func closureDecides() {
        let names = graph().finalImageProducts(containing: "Library").map(\.name)
        #expect(names == ["LibDyn", "tool"])
        #expect(!names.contains("unrelated"))
        #expect(!names.contains("LibStatic"))
    }

    @Test("a target nothing final depends on has no product images")
    func noFinalImage() {
        #expect(graph().finalImageProducts(containing: "Unrelated").map(\.name) == ["unrelated"])
        #expect(graph().finalImageProducts(containing: "Tests").isEmpty)
    }

    @Test("the resolver adds the child executable's image to the test bundle's, and never an unrelated one")
    func resolverAddsOnlyDependentProducts() throws {
        func found(_ name: String, _ byte: UInt8) throws -> DiscoveredImage {
            let built = try image("/b/\(name)", byte)
            return DiscoveredImage(bundleName: name, binaryPath: built.binaryPath, contentHash: built.contentHash, slices: built.slices)
        }
        let bundle = try found("PackageTests", 0x01)
        let tool = try found("tool", 0x02)
        let unrelated = try found("unrelated", 0x03)
        let resolved = try SwiftPMCompilationUnitImageResolver.resolve(
            targets: ["Library"], graph: graph(), discovered: [bundle], productImages: ["tool": tool, "unrelated": unrelated]
        )
        #expect(resolved["Library"]?.map(\.binaryPath) == [bundle.binaryPath, tool.binaryPath])
    }

    @Test("a product that was not built contributes no image")
    func unbuiltProductIsSkipped() throws {
        let bundle = DiscoveredImage(
            bundleName: "PackageTests", binaryPath: "/b/PackageTests",
            contentHash: SHA256Digest.of("x"), slices: try image("/b/PackageTests", 0x01).slices
        )
        let resolved = try SwiftPMCompilationUnitImageResolver.resolve(
            targets: ["Library"], graph: graph(), discovered: [bundle], productImages: [:]
        )
        #expect(resolved["Library"]?.map(\.binaryPath) == ["/b/PackageTests"])
    }

    @Test("swift package describe's product types decode to executable, dynamic library or other")
    func describeProductTypesDecode() throws {
        let json = """
        {"targets":[],"products":[
          {"name":"tool","targets":["Tool"],"type":{"executable":null}},
          {"name":"dyn","targets":["Library"],"type":{"library":["dynamic"]}},
          {"name":"auto","targets":["Library"],"type":{"library":["automatic"]}}]}
        """
        let decoded = try JSONDecoder().decode(SwiftPMTargetResolver.DescribeOutput.self, from: Data(json.utf8))
        #expect(decoded.products.map(\.kind) == [.executable, .dynamicLibrary, .other])
    }

    @Test("a HIT forged with an unrelated executable's UUID is refused, however well-formed the rest is")
    func forgedUnrelatedExecutableIsRefused() throws {
        let test = try image("/b/PackageTests.xctest/PackageTests", 0x01)
        let tool = try image("/b/tool", 0x02)
        let unrelated = try image("/b/unrelated", 0x03)
        let built = try receipt(images: [test, tool, unrelated], units: [unit(containing: [test.imageID, tool.imageID])])
        func events(_ imageUUID: ImageUUID) -> [RuntimeEventRecord] {
            [
                .startup(RuntimeStartupEvent(
                    runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
                    compilationUnitID: schemataFixtureCompilationUnitID, token: schemataFixtureToken, processID: 200,
                    imageUUID: imageUUID, runtimeABIVersion: 3
                )),
                .hit(RuntimeHitEvent(
                    runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
                    compilationUnitID: schemataFixtureCompilationUnitID, token: schemataFixtureToken, processID: 200, sequence: 2,
                    imageUUID: imageUUID, runtimeABIVersion: 3
                ))
            ]
        }
        func verify(_ imageUUID: ImageUUID) -> Bool {
            let observation = SchemataExecutionObservation(
                expectation: makeSchemataExpectation(), buildReceipt: built,
                transcript: RuntimeTranscript(protocolVersion: 3, records: events(imageUUID))
            )
            return (try? MutationVerdictVerifier.verifySchemataChain(observation)) != nil
        }
        #expect(verify(uuid(0x02)), "the dependent executable's own STARTUP/HIT proves the chain")
        #expect(!verify(uuid(0x03)), "an executable outside the unit's containing set proves nothing")
    }
}
