
/// A small, self-contained seeded PRNG (SplitMix64).
///
/// `SystemRandomNumberGenerator` is seeded from the OS and cannot reproduce a
/// sequence, which makes it useless for a plan that must be identical on every
/// machine that reads the same config. This generator's entire state is the seed
/// the user wrote down, so `--seed 42` means the same 200 mutants today, in CI,
/// and in six months.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Process-independent hashing for anything that steers a decision.
public enum StableHash {
    /// FNV-1a, 64-bit.
    ///
    /// Swift's `Hasher` is seeded per process, so `"a".hashValue` differs
    /// between two runs of the same binary. Anything derived from it — shard
    /// assignment, budget sampling — would silently stop being reproducible.
    /// This function has no hidden seed.
    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
