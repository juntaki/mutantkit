import Testing
import MatrixWidget

/// Other half of the coverage — see MatrixWidgetXCTestTests.swift's own
/// doc comment.
@Suite("MatrixWidget (Swift Testing half)")
struct MatrixWidgetSwiftTestingTests {
    @Test
    func isInvalid() {
        #expect(MatrixWidget.isInvalid(flag: false))
        #expect(!MatrixWidget.isInvalid(flag: true))
    }

    @Test
    func greeting() {
        #expect(MatrixWidget.greeting() == "hello")
    }

    @Test
    func label() {
        #expect(MatrixWidget.label(flag: true) == "yes")
        #expect(MatrixWidget.label(flag: false) == "no")
    }
}
