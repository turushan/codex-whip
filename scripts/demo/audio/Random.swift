// Seeded, deterministic random numbers. Nothing here reads the clock or the
// system generator, so the same plan always yields the same noise.

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    @inline(__always)
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in [0, 1).
    @inline(__always)
    mutating func unit() -> Double {
        Double(next() >> 11) * 0x1p-53
    }

    /// Uniform value in [-1, 1).
    @inline(__always)
    mutating func bipolar() -> Double {
        unit() * 2 - 1
    }

    @inline(__always)
    mutating func range(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * unit()
    }

    mutating func below(_ count: Int) -> Int {
        Int(next() % UInt64(max(1, count)))
    }
}

/// Stable 64-bit FNV-1a hash. Swift's Hasher is seeded per process, so it
/// must never feed the audio.
func stableHash(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
}

/// Derives a seed from a tag and integer coordinates such as a sample index.
func seed(_ tag: String, _ values: Int...) -> UInt64 {
    var mixer = SplitMix64(seed: stableHash(tag) ^ 0x5EED_C0DE_2026_1026)
    var result = mixer.next()
    for value in values {
        var step = SplitMix64(seed: result ^ UInt64(bitPattern: Int64(value)))
        result = step.next()
    }
    return result
}
