import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// RED tests for `apple.persistence.required-decode-introduction`. Positive
/// scenarios prove discovery finds the real fault-shaped canonical
/// `decodeIfPresent(...) ?? fallback` site; negative scenarios prove each
/// constraint in the operator's own doc comment actually fires, each
/// independently verified against a real `swiftc -typecheck`/`swiftc` compile
/// (not merely asserted from syntax alone) — see
/// `RequiredDecodeIntroductionCompileViabilityAcceptanceTests` for the
/// compile-time proof of the shapes this suite claims are compile-safe to
/// mutate.
@Suite("RED: Apple persistence required-decode-introduction operator")
struct RequiredDecodeIntroductionOperatorREDTests {
    private let operatorID = "apple.persistence.required-decode-introduction"

    // MARK: - Positive scenarios

    @Test("The canonical decodeIfPresent(...) ?? fallback shape is a candidate")
    func canonicalShapeIsCandidate() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try container.decodeIfPresent(Int.self, forKey: .value) ?? 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains {
            $0.originalText == "container.decodeIfPresent(Int.self, forKey: .value) ?? 0" &&
                $0.replacementText == "container.decode(Int.self, forKey: .value)"
        })
    }

    @Test("An array element type works the same way")
    func arrayElementTypeIsCandidate() throws {
        let source = """
        struct Model: Decodable {
            let tags: [String]
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains {
            $0.originalText == "container.decodeIfPresent([String].self, forKey: .tags) ?? []" &&
                $0.replacementText == "container.decode([String].self, forKey: .tags)"
        })
    }

    @Test("A nested container's decodeIfPresent(...) ?? fallback is also a candidate")
    func nestedContainerIsCandidate() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            init(from decoder: Decoder) throws {
                let nested = try decoder.container(keyedBy: CodingKeys.self)
                    .nestedContainer(keyedBy: NestedKeys.self, forKey: .inner)
                value = try nested.decodeIfPresent(Int.self, forKey: .value) ?? 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains {
            $0.originalText == "nested.decodeIfPresent(Int.self, forKey: .value) ?? 0" &&
                $0.replacementText == "nested.decode(Int.self, forKey: .value)"
        })
    }

    @Test("A fallback with a side effect is still a candidate (dropping it is the intended mutation)")
    func fallbackWithSideEffectIsStillCandidate() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try container.decodeIfPresent(Int.self, forKey: .value) ?? Self.computeDefault()
            }
            static func computeDefault() -> Int { 0 }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains {
            $0.originalText == "container.decodeIfPresent(Int.self, forKey: .value) ?? Self.computeDefault()" &&
                $0.replacementText == "container.decode(Int.self, forKey: .value)"
        })
    }

    // MARK: - Negative scenarios

    @Test("Bare decodeIfPresent(...) with no ?? fallback is excluded")
    func bareDecodeIfPresentWithNoFallbackIsExcluded() throws {
        let source = """
        struct Model: Decodable {
            let value: Int?
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try container.decodeIfPresent(Int.self, forKey: .value)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("decodeIfPresent") })
    }

    @Test("try? decodeIfPresent(...) ?? fallback is excluded (a different, already-tolerant shape)")
    func tryOptionalIsExcluded() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = (try? container.decodeIfPresent(Int.self, forKey: .value)) ?? 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("decodeIfPresent") })
    }

    @Test("try! decodeIfPresent(...) ?? fallback is excluded")
    func tryForceIsExcluded() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try! container.decodeIfPresent(Int.self, forKey: .value) ?? 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("decodeIfPresent") })
    }

    @Test("The single-argument UnkeyedDecodingContainer overload (no forKey:) is excluded")
    func unkeyedOverloadIsExcluded() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                value = try container.decodeIfPresent(Int.self) ?? 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("decodeIfPresent") })
    }

    @Test("A call with more than two arguments is excluded")
    func extraArgumentIsExcluded() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try container.decodeIfPresent(Int.self, forKey: .value, extra: true) ?? 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("decodeIfPresent") })
    }

    @Test("A first argument that is not a <Type>.self expression is excluded")
    func nonSelfFirstArgumentIsExcluded() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = Int.self
                value = try container.decodeIfPresent(type, forKey: .value) ?? 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("decodeIfPresent") })
    }

    @Test("A second argument not labeled forKey: is excluded")
    func nonForKeyLabelIsExcluded() throws {
        let source = """
        struct Model {
            let value: Int
            init(json: [String: Any]) {
                value = MyDecoder.decodeIfPresent(Int.self, from: json) ?? 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("decodeIfPresent") })
    }

    @Test("A differently-named method (decodeIfPresentAll) is not matched")
    func differentlyNamedMethodIsExcluded() throws {
        let source = """
        struct Model: Decodable {
            let value: Int
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try container.decodeIfPresentAll(Int.self, forKey: .value) ?? 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("decodeIfPresentAll") })
    }

    @Test("decodeIfPresent(...) not under any try (a non-throwing custom API) is excluded")
    func noTryAtAllIsExcluded() throws {
        let source = """
        struct Model {
            let value: Int
            init(container: SomeNonThrowingContainer) {
                value = container.decodeIfPresent(Int.self, forKey: "value") ?? 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("decodeIfPresent") })
    }
}
