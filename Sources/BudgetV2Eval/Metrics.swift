import MutationModel

/// The two candidate primary metrics (protocol §3.1/§3.2), each a pure
/// function of a selected `MutationPoint` set against a corpus's full
/// pre-collected outcome data (§5.2) — never re-executes anything.
enum Metric: String, CaseIterable {
    case m1SoleKillerTests
    case m2DistinctKilledDeclarations

    func value(selected: [MutationPoint], corpus: Corpus) -> Int {
        switch self {
        case .m1SoleKillerTests:
            var soleKillerTests = Set<String>()
            for point in selected {
                guard corpus.outcomes[point.id]?.isKilled == true else { continue }
                let tests = corpus.failingTests[point.id] ?? []
                if tests.count == 1 {
                    soleKillerTests.insert(tests[0])
                }
            }
            return soleKillerTests.count
        case .m2DistinctKilledDeclarations:
            var killedDeclarations = Set<String>()
            for point in selected {
                guard corpus.outcomes[point.id]?.isKilled == true else { continue }
                killedDeclarations.insert(Corpus.declarationKey(point))
            }
            return killedDeclarations.count
        }
    }
}

/// §3.5's non-inferiority kill rate: `killed / (killed + survived)` over a
/// selected set, restricted to classified (`killed`/`survived`) outcomes.
/// `nil` when the denominator is zero — the zero-denominator case §3.5
/// requires callers to treat as inconclusive, not as a pass.
func killRate(selected: [MutationPoint], corpus: Corpus) -> Double? {
    var killed = 0
    var survived = 0
    for point in selected {
        guard let outcome = corpus.outcomes[point.id] else { continue }
        if outcome.isKilled {
            killed += 1
        } else if outcome == .survived {
            survived += 1
        }
    }
    let denominator = killed + survived
    guard denominator > 0 else { return nil }
    return Double(killed) / Double(denominator)
}
