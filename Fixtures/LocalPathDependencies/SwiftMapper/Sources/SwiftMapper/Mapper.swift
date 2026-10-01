import Logging

public enum Mapper {
    public static func scaled(_ value: Int) -> Int {
        Trace.note("scaled")
        return value * 2
    }
}
