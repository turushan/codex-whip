import Foundation

// ITU-R BS.1770-4 loudness (K-weighting, 400 ms blocks with 75% overlap,
// absolute and relative gates), EBU Tech 3342 loudness range, and true peak
// from a 4x oversampled reconstruction.

struct LoudnessMeasurement {
    let integrated: Double
    let range: Double
    let momentaryMax: Double
    let shortTermMax: Double
}

enum Loudness {
    @inline(__always) static func lufs(_ meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -200
    }

    /// Prefix sums of the K-weighted power summed over both channels (G = 1).
    static func weightedPrefix(_ left: [Double], _ right: [Double]) -> [Double] {
        // Coefficients from BS.1770-4 for 48 kHz.
        let shelf = Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                           a1: -1.69065929318241, a2: 0.73248077421585)
        let highpass = Biquad(b0: 1.0, b1: -2.0, b2: 1.0, a1: -1.99004745483398, a2: 0.99007225036621)
        var shelfL = shelf
        var shelfR = shelf
        var highL = highpass
        var highR = highpass
        let count = left.count
        var prefix = [Double](repeating: 0, count: count + 1)
        var sum = 0.0
        for i in 0..<count {
            let l = highL.process(shelfL.process(left[i]))
            let r = highR.process(shelfR.process(right[i]))
            sum += l * l + r * r
            prefix[i + 1] = sum
        }
        return prefix
    }

    static func blocks(_ prefix: [Double], window: Int, hop: Int) -> [Double] {
        var result: [Double] = []
        var start = 0
        let count = prefix.count - 1
        while start + window <= count {
            result.append((prefix[start + window] - prefix[start]) / Double(window))
            start += hop
        }
        return result
    }

    static func gatedIntegrated(_ blocks: [Double]) -> Double {
        let absolute = blocks.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return -200 }
        let threshold = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > threshold }
        guard !gated.isEmpty else { return -200 }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    static func integrated(_ left: [Double], _ right: [Double]) -> Double {
        gatedIntegrated(blocks(weightedPrefix(left, right), window: 19_200, hop: 4_800))
    }

    static func measure(_ left: [Double], _ right: [Double]) -> LoudnessMeasurement {
        let prefix = weightedPrefix(left, right)
        let momentary = blocks(prefix, window: 19_200, hop: 4_800)
        let shortTerm = blocks(prefix, window: 144_000, hop: 4_800)
        return LoudnessMeasurement(
            integrated: gatedIntegrated(momentary),
            range: loudnessRange(shortTerm),
            momentaryMax: lufs(momentary.max() ?? 0),
            shortTermMax: lufs(shortTerm.max() ?? 0)
        )
    }

    /// EBU Tech 3342: short-term values above -70 LUFS and within 20 LU of
    /// their mean; the range is the 10th to 95th percentile spread.
    static func loudnessRange(_ shortTerm: [Double]) -> Double {
        let absolute = shortTerm.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return 0 }
        let threshold = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 20
        let values = absolute.map(lufs).filter { $0 > threshold }.sorted()
        guard values.count > 1 else { return 0 }
        func percentile(_ p: Double) -> Double {
            let x = p * Double(values.count - 1)
            let i = Int(x)
            let f = x - Double(i)
            return i + 1 < values.count ? values[i] + f * (values[i + 1] - values[i]) : values[i]
        }
        return percentile(0.95) - percentile(0.10)
    }
}

/// Polyphase 4x interpolator: 32 taps per phase from a 129-tap Kaiser
/// windowed sinc. Phase 0 is the original sample.
enum TruePeak {
    static let taps = 32
    /// Three phases (1/4, 2/4, 3/4) of 32 coefficients each, applied to
    /// samples m - 15 ... m + 16 to estimate the value at m + phase/4.
    static let coefficients: [Double] = {
        let length = 129
        let center = 64.0
        let beta = 8.0
        func besselI0(_ x: Double) -> Double {
            var sum = 1.0
            var term = 1.0
            var k = 1.0
            while term > 1e-12 * sum {
                term *= (x / (2 * k)) * (x / (2 * k))
                sum += term
                k += 1
            }
            return sum
        }
        var prototype = [Double](repeating: 0, count: length)
        for n in 0..<length {
            let d = (Double(n) - center) / 4
            let sinc = d == 0 ? 1 : sin(Double.pi * d) / (Double.pi * d)
            let r = (Double(n) - center) / center
            prototype[n] = sinc * besselI0(beta * max(0, 1 - r * r).squareRoot()) / besselI0(beta)
        }
        var result: [Double] = []
        for phase in 1...3 {
            var c = [Double](repeating: 0, count: taps)
            for q in 0..<taps {
                c[q] = prototype[124 + phase - 4 * q]
            }
            let sum = c.reduce(0, +)
            result += c.map { $0 / sum }
        }
        return result
    }()

    /// Largest absolute value of the 4x oversampled reconstruction of one channel.
    static func peak(_ x: [Double]) -> Double {
        let n = x.count
        var best = 0.0
        let c = coefficients
        x.withUnsafeBufferPointer { p in
            c.withUnsafeBufferPointer { h in
                for m in 0..<n {
                    best = max(best, abs(p[m]))
                }
                guard n > taps + 2 else { return }
                for m in 15..<(n - 17) {
                    let base = p.baseAddress! + (m - 15)
                    var a1 = 0.0
                    var a2 = 0.0
                    var a3 = 0.0
                    for q in 0..<taps {
                        let s = base[q]
                        a1 += h[q] * s
                        a2 += h[taps + q] * s
                        a3 += h[2 * taps + q] * s
                    }
                    best = max(best, abs(a1), abs(a2), abs(a3))
                }
            }
        }
        return best
    }

    /// Per-sample required gain so the reconstruction stays under `ceiling`.
    /// Interpolation runs only near material within 6 dB of the ceiling.
    static func requiredGain(_ left: [Double], _ right: [Double], ceiling: Double) -> [Double] {
        let n = left.count
        var required = [Double](repeating: 1, count: n)
        let blockSize = 16
        let blockCount = (n + blockSize - 1) / blockSize
        var blockMax = [Double](repeating: 0, count: blockCount)
        for m in 0..<n {
            let s = max(abs(left[m]), abs(right[m]))
            if s > ceiling {
                required[m] = min(required[m], ceiling / s)
            }
            blockMax[m / blockSize] = max(blockMax[m / blockSize], s)
        }
        let threshold = ceiling * 0.5
        let c = coefficients
        for b in 0..<blockCount {
            var local = 0.0
            for k in max(0, b - 3)...min(blockCount - 1, b + 3) {
                local = max(local, blockMax[k])
            }
            guard local > threshold else { continue }
            for m in (b * blockSize)..<min(n, (b + 1) * blockSize) where m >= 15 && m < n - 17 {
                var peak = 0.0
                for channel in [left, right] {
                    var a1 = 0.0
                    var a2 = 0.0
                    var a3 = 0.0
                    for q in 0..<taps {
                        let s = channel[m - 15 + q]
                        a1 += c[q] * s
                        a2 += c[taps + q] * s
                        a3 += c[2 * taps + q] * s
                    }
                    peak = max(peak, abs(a1), abs(a2), abs(a3))
                }
                if peak > ceiling {
                    let g = ceiling / peak
                    required[m] = min(required[m], g)
                    required[m + 1] = min(required[m + 1], g)
                }
            }
        }
        return required
    }
}
