/// The one mutation candidate this fixture exists for: a relational
/// operator replacement (`==` → `!=`) — the smallest mutation family
/// confirmed registered by both MutantKit and Muter. A bool-literal
/// fixture was tried first and produced zero mutations from Muter,
/// because Muter's own operator set does not include
/// bool-literal-inversion; RelationalOperatorReplacement is the correct
/// shared target for this gate.
public func isZero(_ value: Int) -> Bool {
    value == 0
}
