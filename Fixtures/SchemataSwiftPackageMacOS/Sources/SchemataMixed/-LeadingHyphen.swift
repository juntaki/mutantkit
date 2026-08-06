// Zero mutation candidates — see NoMutationCandidate.swift's own doc
// comment for what this regression fixture proves. This one covers a
// leading hyphen in the filename itself, which a shell (or any code
// treating a path as a command-line argument rather than a real argv
// element) could otherwise misparse as a flag.
public func identityLeadingHyphen(_ value: Int) -> Int {
    value
}
