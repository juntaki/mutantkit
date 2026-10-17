import Core

public enum Pricing {
    public static func needsReview(units: Int) -> Bool {
        Limits.isOverLimit(units) || units < 0
    }

    public static func isFree(units: Int) -> Bool {
        units == 0
    }
}
