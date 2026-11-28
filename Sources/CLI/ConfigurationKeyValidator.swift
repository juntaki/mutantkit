import Foundation
import MutationModel
import Yams

/// Rejects configuration keys the published schema does not declare.
///
/// The typed `Configuration` decode ignores keys it does not know, so a
/// misspelled `workerz:` would otherwise silently fall back to a default. (A key
/// written twice in one mapping is already rejected by the YAML parser itself.) The allowed key set is read
/// from `ConfigurationJSONSchema.document` itself, so the contract an editor is
/// shown and the contract the loader enforces cannot drift apart.
enum ConfigurationKeyValidator {
    static func validate(_ root: Node) throws {
        try validate(root, schemaDocument: ConfigurationJSONSchema.document)
    }

    /// Fails closed: a schema that cannot be parsed means no key can be vouched
    /// for, which is an error rather than "everything is allowed".
    static func validate(_ root: Node, schemaDocument: String) throws {
        let schema: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(schemaDocument.utf8)) as? [String: Any],
                  object["properties"] is [String: Any]
            else { throw ConfigurationKeyError.schemaUnavailable(reason: "not an object with properties") }
            schema = object
        } catch let error as ConfigurationKeyError {
            throw error
        } catch {
            throw ConfigurationKeyError.schemaUnavailable(reason: "\(error)")
        }
        try rejectUnknown(root, schema: schema, path: "")
    }

    private static func rejectUnknown(_ node: Node, schema: [String: Any], path: String) throws {
        guard case let .mapping(mapping) = node,
              let properties = schema["properties"] as? [String: Any]
        else { return }
        let allowsOthers = schema["additionalProperties"] as? Bool != false
        for (key, value) in mapping {
            let name = key.string ?? "\(key)"
            // YAML merge key: the merged mapping(s) contribute keys to this
            // section, so they are checked against this same section.
            if name == "<<" {
                let merged: [Node]
                if case let .sequence(items) = value { merged = Array(items) } else { merged = [value] }
                for item in merged { try rejectUnknown(item, schema: schema, path: path) }
                continue
            }
            guard let subschema = properties[name] as? [String: Any] else {
                if allowsOthers { continue }
                throw ConfigurationKeyError.unknown(parent: path, key: name, allowed: properties.keys.sorted())
            }
            try rejectUnknown(value, schema: subschema, path: join(path, name))
        }
    }

    private static func join(_ path: String, _ name: String) -> String {
        path.isEmpty ? name : "\(path).\(name)"
    }
}

enum ConfigurationKeyError: Error {
    case unknown(parent: String, key: String, allowed: [String])
    case schemaUnavailable(reason: String)
}
