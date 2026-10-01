import SwiftMapper

/// Decides whether a mapped value is large. The comparison lives here, in
/// the mutated package; the mapping it depends on lives in a sibling.
public enum Threshold {
    public static func isLarge(_ value: Int) -> Bool {
        Mapper.scaled(value) >= 10
    }
}
