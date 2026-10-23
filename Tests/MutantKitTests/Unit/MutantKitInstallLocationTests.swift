@testable import AppleBuildAdapters
import Foundation
import Testing

@Suite("MutantKit install location")
struct MutantKitInstallLocationTests {
    @Test("The running executable's location is its symlink-resolved path")
    func executableURLIsTheResolvedExecutablePath() throws {
        let path = try #require(Bundle.main.executablePath)
        let url = try #require(MutantKitInstallLocation.executableURL())
        #expect(url == URL(fileURLWithPath: path).resolvingSymlinksInPath())
    }
}
