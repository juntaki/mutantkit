import Foundation

extension XcodeTargetResolver {
    /// The `.xcodeproj` files a workspace references, in document order. `group:` paths are
    /// relative to the enclosing `Group` (itself `group:`-relative), `container:` to the
    /// workspace's directory, `absolute:` as written; `self:` (the workspace's own project) and
    /// anything that is not an `.xcodeproj` are skipped. Exposed for unit testing.
    static func parseWorkspaceMemberProjects(
        workspaceData: Data, workspaceContainer: URL, workspacePath: String
    ) throws -> [URL] {
        let collector = WorkspaceDataCollector(container: workspaceContainer)
        let parser = XMLParser(data: workspaceData)
        parser.delegate = collector
        guard parser.parse() else {
            throw ResolutionError.workspaceUnreadable(
                path: workspacePath, underlying: parser.parserError.map { "\($0)" } ?? "not valid XML"
            )
        }
        var seen: Set<String> = []
        return collector.projects.filter { seen.insert($0.path).inserted }
    }

    private final class WorkspaceDataCollector: NSObject, XMLParserDelegate {
        let container: URL
        var projects: [URL] = []
        private var groupStack: [String] = []

        init(container: URL) { self.container = container }

        private func resolve(_ location: String, groups: [String]) -> URL? {
            guard let colon = location.firstIndex(of: ":") else { return nil }
            let kind = location[..<colon]
            let path = String(location[location.index(after: colon)...])
            switch kind {
            case "group":
                return (groups + [path]).reduce(container) { $0.appendingPathComponent($1) }
            case "container":
                return container.appendingPathComponent(path)
            case "absolute":
                return URL(fileURLWithPath: path)
            default:
                return nil
            }
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard let location = attributeDict["location"] else {
                if elementName == "Group" { groupStack.append("") }
                return
            }
            switch elementName {
            case "Group":
                // A group's own location is `group:<dir>` relative to its parent group.
                groupStack.append(location.hasPrefix("group:") ? String(location.dropFirst("group:".count)) : "")
            case "FileRef":
                if let url = resolve(location, groups: groupStack.filter { !$0.isEmpty }), url.pathExtension == "xcodeproj" {
                    projects.append(url.standardizedFileURL)
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "Group" { _ = groupStack.popLast() }
        }
    }
}
