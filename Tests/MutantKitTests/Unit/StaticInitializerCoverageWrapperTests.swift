import Foundation
import SwiftFrontend
import SwiftParser
import Testing

@Suite("Wrapping static initializers for a coverage build")
struct StaticInitializerCoverageWrapperTests {
    private func rewrite(_ source: String, isMainFile: Bool = false) -> String? {
        StaticInitializerCoverageWrapper.rewrite(source, isMainFile: isMainFile)
    }

    @Test("A static let is wrapped on the lines it already occupies")
    func wrapsStaticLetKeepingLines() throws {
        let source = """
        struct Op {
            static let descriptor = Descriptor(
                eligible: false
            )
        }
        """
        let result = try #require(rewrite(source))
        #expect(result.contains("static let descriptor = { Descriptor("))
        #expect(result.contains("    ) }()"))
        #expect(result.split(separator: "\n", omittingEmptySubsequences: false).count
            == source.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    @Test("A global in a file other than main.swift is wrapped, one in main.swift is not")
    func globals() {
        #expect(rewrite("let shared = Cache()\n") == "let shared = { Cache() }()\n")
        #expect(rewrite("let shared = Cache()\n", isMainFile: true) == nil)
    }

    @Test("An eligible declaration nested in a type is found, a local is not", arguments: [
        ("enum A { enum B { static var x: Int = 1 } }", true),
        ("extension A { class var y: Int { 1 } }", false),
        ("func f() { let z = 1 }", false),
        ("struct S { static func g() { let z = Foo() } }", false),
        ("struct S { let instance = Foo() }", false),
        ("struct S { lazy var l = Foo() }", false),
        ("struct S { static var observed = 1 { didSet {} } }", false),
        ("struct S { static let a = 1, b = 2 }", false),
        ("struct S { static let (a, b) = (1, 2) }", false)
    ])
    func eligibility(source: String, wrapped: Bool) {
        #expect((rewrite(source) != nil) == wrapped)
    }

    @Test("Initializers the closure could type differently are left alone", arguments: [
        "struct S { static let a = .init() }",
        "struct S { static let a = nil }",
        "struct S { static let a: some P = Foo() }",
        "struct S { static let a = { Foo() }() }",
        "struct S { @TaskLocal static let a = 1 }"
    ])
    func skipsRiskyShapes(source: String) {
        #expect(rewrite(source) == nil)
    }

    @Test("An annotated implicit member is wrapped, the type comes from the annotation")
    func annotatedImplicitMember() {
        #expect(rewrite("struct S { static let a: Mode = .fast }") == "struct S { static let a: Mode = { .fast }() }")
    }

    @Test("MainActor is kept, and the result parses without errors")
    func mainActorAndValidity() throws {
        let result = try #require(rewrite("@MainActor struct S { @MainActor static let a = Foo(x: [1, 2]) // c\n}\n"))
        #expect(result.contains("static let a = { Foo(x: [1, 2]) }() // c"))
        #expect(!Parser.parse(source: result).hasError)
    }
}
