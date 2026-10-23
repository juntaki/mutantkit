import Testing

@testable import Beta

@Suite("Beta")
struct BetaTests {
    @Test("more than 100 is large")
    func largeBoundary() {
        #expect(Beta.isLarge(count: 100) == false)
        #expect(Beta.isLarge(count: 101) == true)
    }
}
