import MutationExecution
import Testing

@Suite("TestIdentifier.onlyTestingArgument")
struct OnlyTestingArgumentTests {
    @Test("A name without a parameter list gets an empty one")
    func xctestNameGetsEmptyParentheses() {
        #expect(TestIdentifier(target: "AppTests", qualifiedName: "AddTests/testAdd").onlyTestingArgument == "AppTests/AddTests/testAdd()")
    }

    @Test("A name that already ends in a parameter list is used as it is, parameterized or not")
    func existingParameterListIsKept() {
        #expect(TestIdentifier(target: "AppTests", qualifiedName: "Suite/method()").onlyTestingArgument == "AppTests/Suite/method()")
        #expect(
            TestIdentifier(target: "AppTests", qualifiedName: "Suite/method(value:)").onlyTestingArgument
                == "AppTests/Suite/method(value:)"
        )
    }
}
