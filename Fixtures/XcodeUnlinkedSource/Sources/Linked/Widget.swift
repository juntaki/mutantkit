import Foundation

/// Boundary-tested. Its mutants should be killed — the run has to prove it
/// can actually distinguish a real, compiled change from no change at all, or
/// the True Negative case in `Sources/Unlinked` would pass for the wrong
/// reason (a suite that kills nothing would also fail to activate this).
public enum Widget {
    public static func isInStock(count: Int) -> Bool {
        count >= 1
    }
}
