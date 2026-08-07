// Deliberately zero mutation candidates of its own (no bool/relational
// literal for any registered operator to touch) — this file's only job is
// to sit in the same target as `Widget.swift`'s embeddable candidates,
// inside a directory whose name contains a space. Regression fixture for
// the bug where SchemataRunOrchestration.classify only read source content
// for files that had a planned mutation, so a target member with none of
// its own (like this one) was missing from the `sources` dictionary
// SchemataChunkPlanner.plan needs to build one compilable chunk for the
// whole target — degrading the whole target to isolated fallback for no
// structural reason. Never actually about the space in the path.
public func identity(_ value: Int) -> Int {
    value
}
