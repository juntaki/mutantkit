import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof, via a real `swiftc` compile, of every compile-safety
/// claim `RequiredDecodeIntroductionOperator`'s own doc comment makes —
/// mirrors `ContinuationResumeRemovalCompileViabilityAcceptanceTests`' own
/// approach. In particular this suite verifies the adversarial-review claim
/// that `T`'s generic inference never depends on the `??` operator here
/// (unlike the continuation operator's `withCheckedContinuation` hazard),
/// across a battery of `T` shapes: a plain value type, an `Optional`-typed
/// `T`, an array, a `RawRepresentable` enum, and a nested `Decodable`
/// struct.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: required-decode-introduction compile viability", .enabled(if: Acceptance.isEnabled))
struct RequiredDecodeIntroductionCompileViabilityAcceptanceTests {
    private let operatorID = "apple.persistence.required-decode-introduction"

    private func compiles(_ source: String) throws -> (succeeded: Bool, output: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("required-decode-introduction-compile-viability-\(UUID().uuidString).swift")
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-o", "/dev/null", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    private func mutatedSource(_ source: String, candidateMatching predicate: (String) -> Bool) throws -> String {
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(
            points.first { predicate($0.originalText) },
            "expected a matching mutation candidate among \(points.map(\.originalText))"
        )
        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        return String(decoding: applied.mutatedSource, as: UTF8.self)
    }

    @Test("A plain value-type field: removing the fallback still type-checks")
    func plainValueTypeRemovalTypeChecks() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            enum CodingKeys: String, CodingKey { case value }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try container.decodeIfPresent(Int.self, forKey: .value) ?? 0
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("decodeIfPresent") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
        #expect(mutated.contains("try container.decode(Int.self, forKey: .value)"))
    }

    @Test("An Optional-typed T (Int?.self): removing the fallback still type-checks")
    func optionalTypedGenericRemovalTypeChecks() throws {
        let source = """
        struct Model: Decodable {
            let value: Int?
            enum CodingKeys: String, CodingKey { case value }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try container.decodeIfPresent(Int?.self, forKey: .value) ?? nil
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("decodeIfPresent") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("An array T ([String].self): removing the fallback still type-checks")
    func arrayGenericRemovalTypeChecks() throws {
        let source = """
        struct Model: Decodable {
            let tags: [String]
            enum CodingKeys: String, CodingKey { case tags }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("decodeIfPresent") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A RawRepresentable enum T: removing the fallback still type-checks")
    func rawRepresentableEnumRemovalTypeChecks() throws {
        let source = """
        enum Status: String, Decodable {
            case active, inactive
        }
        struct Model: Decodable {
            let status: Status
            enum CodingKeys: String, CodingKey { case status }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .inactive
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("decodeIfPresent") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A nested custom Decodable struct T: removing the fallback still type-checks")
    func nestedDecodableStructRemovalTypeChecks() throws {
        let source = """
        struct Address: Decodable, Equatable {
            let city: String
        }
        struct Model: Decodable {
            let address: Address
            enum CodingKeys: String, CodingKey { case address }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                address = try container.decodeIfPresent(Address.self, forKey: .address) ?? Address(city: "Unknown")
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("decodeIfPresent") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A nested container's decodeIfPresent(...) ?? fallback: removing the fallback still type-checks")
    func nestedContainerRemovalTypeChecks() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            enum OuterKeys: String, CodingKey { case inner }
            enum NestedKeys: String, CodingKey { case value }
            init(from decoder: Decoder) throws {
                let nested = try decoder.container(keyedBy: OuterKeys.self)
                    .nestedContainer(keyedBy: NestedKeys.self, forKey: .inner)
                value = try nested.decodeIfPresent(Int.self, forKey: .value) ?? 0
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("decodeIfPresent") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A fallback with a side effect: removing it (dropping the side effect too) still type-checks")
    func fallbackWithSideEffectRemovalTypeChecks() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            enum CodingKeys: String, CodingKey { case value }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try container.decodeIfPresent(Int.self, forKey: .value) ?? Self.computeDefault()
            }
            static func computeDefault() -> Int { 0 }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source) { $0.contains("decodeIfPresent") }
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }
}
