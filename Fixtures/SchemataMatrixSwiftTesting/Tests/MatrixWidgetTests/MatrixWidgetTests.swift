import Testing
import MatrixWidget

@Suite("MatrixWidget")
struct MatrixWidgetTests {
    @Test
    func isFeatureEnabled() {
        #expect(MatrixWidget.isFeatureEnabled())
    }

    @Test
    func isAdultBoundary() {
        #expect(!MatrixWidget.isAdult(age: 17))
        #expect(MatrixWidget.isAdult(age: 18))
        #expect(MatrixWidget.isAdult(age: 19))
    }

    @Test
    func bothRequired() {
        #expect(MatrixWidget.bothRequired(a: true, b: true))
        #expect(!MatrixWidget.bothRequired(a: true, b: false))
        #expect(!MatrixWidget.bothRequired(a: false, b: true))
        #expect(!MatrixWidget.bothRequired(a: false, b: false))
    }

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
