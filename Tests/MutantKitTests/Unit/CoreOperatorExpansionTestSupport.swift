import Foundation
import MutationModel
import MutationPlanner
import SwiftFrontend

/// Shared support for the operator-expansion RED suites.
///
/// The tests resolve operators through the production registry instead of
/// referring to not-yet-existing concrete types. That keeps the branch
/// compilable: until an operator is implemented and registered, its tests fail
/// with a precise missing-operator error rather than stopping the whole test
/// target at type checking.
enum CoreOperatorExpansionTestSupport {
    struct MissingOperator: Error, CustomStringConvertible {
        let id: String
        let known: [String]

        var description: String {
            "Expected built-in operator '\(id)'. Known operators: \(known.joined(separator: ", "))."
        }
    }

    static func discover(
        _ source: String,
        operatorID: String,
        relativePath: String = "Sample.swift"
    ) throws -> [MutationPoint] {
        let registry = MutationRegistry()
        guard let mutationOperator = registry.operator(withID: operatorID) else {
            throw MissingOperator(
                id: operatorID,
                known: registry.allDescriptors.map(\.id).sorted()
            )
        }

        return try MutationDiscovery(operators: [mutationOperator])
            .discover(source: Data(source.utf8), relativePath: relativePath)
    }

    static func replacementPairs(_ points: [MutationPoint]) -> Set<String> {
        Set(points.map { "\($0.originalText) -> \($0.replacementText)" })
    }
}
