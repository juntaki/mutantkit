import Foundation

/// Two functions on two distinct lines, so a per-test coverage map can
/// attribute each to exactly one test -- see
/// `PerTestProfilingPartialFailureTests`. Xcode-side mirror of
/// `Fixtures/PerTestProfilingPartialFailure`'s own SwiftPM `Widgets.swift`.
public enum PerTestWidgets {
    public static func widgetA() -> Int { 1 }
    public static func widgetB() -> Int { 2 }
}
