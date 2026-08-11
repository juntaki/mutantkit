public func killedFlag() -> Bool {
    true
}

public func survivedFlag() -> Bool {
    true
}

public func pick(_ flag: Bool) -> Int {
    flag ? 1 : 2
}
