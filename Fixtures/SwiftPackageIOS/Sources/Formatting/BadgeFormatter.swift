import UIKit

/// Depends on UIKit specifically so that building this package for the host
/// platform cannot silently succeed.
public enum BadgeFormatter {
    /// Well tested at the boundary — its mutants should be killed.
    public static func text(forCount count: Int) -> String {
        if count > 99 {
            return "99+"
        }
        return String(count)
    }

    /// Not tested — its mutants should survive.
    public static func isProminent(count: Int) -> Bool {
        count >= 10
    }

    public static func color(forCount count: Int) -> UIColor {
        isProminent(count: count) ? .systemRed : .systemGray
    }
}
