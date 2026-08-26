import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import SwiftParser

// MARK: - Operator sets

enum Operators {
    static var all: [any MutationOperator] {
        [BoolLiteralInversionOperator(), RelationalOperatorReplacementOperator()]
    }

    static var boolLiteral: [any MutationOperator] { [BoolLiteralInversionOperator()] }
    static var relational: [any MutationOperator] { [RelationalOperatorReplacementOperator()] }
    static var logicalConnector: [any MutationOperator] { [LogicalConnectorReplacementOperator()] }
    static var arithmetic: [any MutationOperator] { [ArithmeticOperatorReplacementOperator()] }
}

// MARK: - Discovery

/// Discovers against in-memory bytes. Every test goes through the same entry
/// point the planner uses, so nothing here can pass by exercising a shortcut the
/// product does not take.
func discover(
    _ source: String,
    path: String = "Sources/Example.swift",
    using operators: [any MutationOperator] = Operators.all
) throws -> [MutationPoint] {
    try MutationDiscovery(operators: operators).discover(source: Data(source.utf8), relativePath: path)
}

// MARK: - Parse validity

/// Whether SwiftParser accepts these bytes without producing error nodes.
///
/// Every mutated output is checked with this: an operator that emits a
/// replacement which does not compile turns the whole mutant into `unviable`
/// noise, and a splice landing at the wrong offset usually shows up here first.
func parsesWithoutError(_ data: Data) -> Bool {
    !Parser.parse(source: String(decoding: data, as: UTF8.self)).hasError
}

func parsesWithoutError(_ source: String) -> Bool {
    parsesWithoutError(Data(source.utf8))
}

// MARK: - Fixtures

/// Swift fixtures are stored as `.swift.txt` so SwiftPM does not try to compile
/// them as part of the test target.
enum Fixture {
    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    static func data(_ name: String) throws -> Data {
        guard let resourceURL = Bundle.module.resourceURL else {
            throw FixtureError.missingResourceBundle
        }
        let url = resourceURL.appendingPathComponent("Fixtures/\(name).swift.txt")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureError.missingFixture(name: name, searched: url.path)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missingResourceBundle
        case missingFixture(name: String, searched: String)

        var description: String {
            switch self {
            case .missingResourceBundle:
                "The test bundle has no resource directory."
            case let .missingFixture(name, searched):
                "Fixture \(name).swift.txt not found at \(searched)."
            }
        }
    }
}

// MARK: - Assertion helpers

extension AnchorFailure {
    /// Lets a test assert on *which* anchor checks failed without restating the
    /// payloads it does not care about.
    var caseName: String {
        switch self {
        case .fileHashMismatch: "fileHashMismatch"
        case .rangeOutOfBounds: "rangeOutOfBounds"
        case .originalTextMismatch: "originalTextMismatch"
        case .noNodeAtRange: "noNodeAtRange"
        case .syntaxKindMismatch: "syntaxKindMismatch"
        case .prefixFingerprintMismatch: "prefixFingerprintMismatch"
        case .suffixFingerprintMismatch: "suffixFingerprintMismatch"
        case .declarationMismatch: "declarationMismatch"
        }
    }
}

extension AnchorVerification {
    var failureNames: [String] { failures.map(\.caseName) }
}

extension [IntegrityViolation] {
    var kinds: [IntegrityViolation.Kind] { map(\.kind) }
}

/// The UTF-8 byte offset of the nth occurrence of `needle`.
///
/// Written against raw bytes rather than `String.Index` so that the expected
/// value in a Unicode test is derived independently of the machinery under test.
func utf8Offset(of needle: String, occurrence: Int = 0, in source: String) -> Int? {
    let haystack = Array(source.utf8)
    let pattern = Array(needle.utf8)
    guard !pattern.isEmpty, haystack.count >= pattern.count else { return nil }

    var found = 0
    for start in 0 ... (haystack.count - pattern.count) where Array(haystack[start ..< start + pattern.count]) == pattern {
        if found == occurrence { return start }
        found += 1
    }
    return nil
}
