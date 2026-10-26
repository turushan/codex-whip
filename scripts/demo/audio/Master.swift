import Foundation

// Master chain: 25 Hz high-pass, mono below 150 Hz, gentle glue compression,
// subtle 2x oversampled saturation, normalization to the loudness target and a
// lookahead true-peak limiter, then fades and 24-bit quantization. The whip bus
// joins after the glue compressor, so a crack keeps the same punch whether it
// lands on a kick or between kicks; it still passes saturation and the limiter.

struct GlueStats {
    let thresholdDbfs: Double
    let ratio: Double
    let averageReductionDb: Double
    let loudReductionDb: Double
    let maxReductionDb: Double
}

struct LimiterStats {
    let ceilingDbtp: Double
    let maxReductionDb: Double
    let limitedMilliseconds: Double
}

struct MasterResult {
    let left: [Int32]
    let right: [Int32]
    let normalizationGainDb: Double
    let preSaturationGainDb: Double
    let glue: GlueStats
    let limiter: LimiterStats
    let saturationDrive: Double
    let iterations: Int
}

enum Master {
    static let targetLufs = -16.0
    static let ceilingDbtp = -1.5
    static let saturationDrive = 0.5
    static let fullScale = 8_388_608.0

    static func process(bed: ([Double], [Double]), whip: ([Double], [Double])) -> MasterResult {
        var left = bed.0
        var right = bed.1
        var whipLeft = whip.0
        var whipRight = whip.1
        highpass(&left, &right)
        monoBass(&left, &right)
        highpass(&whipLeft, &whipRight)
        monoBass(&whipLeft, &whipRight)
        let glue = glueCompress(&left, &right)
        for i in 0..<left.count {
            left[i] += whipLeft[i]
            right[i] += whipRight[i]
        }

        // Saturate at the delivery level so its amount does not depend on the mix gain.
        let preGain = dbToGain(targetLufs - Loudness.integrated(left, right))
        scale(&left, &right, preGain)
        saturate(&left, &right, drive: saturationDrive)

        // Normalize, limit, fade; repeat until the limited result sits on target.
        var gain = dbToGain(targetLufs - Loudness.integrated(left, right))
        var ceiling = dbToGain(ceilingDbtp - 0.02)
        var outLeft: [Double] = []
        var outRight: [Double] = []
        var limiter = LimiterStats(ceilingDbtp: ceilingDbtp, maxReductionDb: 0, limitedMilliseconds: 0)
        var iterations = 0
        for iteration in 0..<10 {
            iterations = iteration + 1
            outLeft = left.map { $0 * gain }
            outRight = right.map { $0 * gain }
            limiter = limit(&outLeft, &outRight, ceiling: ceiling)
            fades(&outLeft, &outRight)
            let truePeak = max(TruePeak.peak(outLeft), TruePeak.peak(outRight))
            if truePeak > dbToGain(ceilingDbtp - 0.005) {
                ceiling *= dbToGain(ceilingDbtp - 0.01) / truePeak
                continue
            }
            let measured = Loudness.integrated(outLeft, outRight)
            if abs(measured - targetLufs) < 0.005 {
                break
            }
            gain *= dbToGain(targetLufs - measured)
        }
        // Guarantee the ceiling even if the loop ran out of passes on an overshoot.
        let finalPeak = max(TruePeak.peak(outLeft), TruePeak.peak(outRight))
        if finalPeak > dbToGain(ceilingDbtp - 0.005) {
            scale(&outLeft, &outRight, dbToGain(ceilingDbtp - 0.01) / finalPeak)
        }
        return MasterResult(left: quantize(outLeft), right: quantize(outRight),
                            normalizationGainDb: gainToDb(gain), preSaturationGainDb: gainToDb(preGain),
                            glue: glue, limiter: limiter, saturationDrive: saturationDrive, iterations: iterations)
    }

    static func scale(_ left: inout [Double], _ right: inout [Double], _ gain: Double) {
        for i in 0..<left.count {
            left[i] *= gain
            right[i] *= gain
        }
    }

    /// Fourth-order Butterworth high-pass at 25 Hz.
    static func highpass(_ left: inout [Double], _ right: inout [Double]) {
        var l1 = Biquad.highpass(25, q: 0.5412)
        var l2 = Biquad.highpass(25, q: 1.3066)
        var r1 = l1
        var r2 = l2
        for i in 0..<left.count {
            left[i] = l2.process(l1.process(left[i]))
            right[i] = r2.process(r1.process(right[i]))
        }
    }

    /// Fourth-order high-pass on the side signal keeps the low end mono below about 150 Hz.
    static func monoBass(_ left: inout [Double], _ right: inout [Double]) {
        var s1 = Biquad.highpass(150, q: 0.5412)
        var s2 = Biquad.highpass(150, q: 1.3066)
        for i in 0..<left.count {
            let mid = 0.5 * (left[i] + right[i])
            let side = s2.process(s1.process(0.5 * (left[i] - right[i])))
            left[i] = mid + side
            right[i] = mid - side
        }
    }

    /// Stereo-linked RMS compressor, 2:1 with a 6 dB knee, 20 ms attack and
    /// 220 ms release. The threshold sits 5 dB under the 90th percentile of the
    /// program level, so loud passages see about 2.5 dB of reduction.
    static func glueCompress(_ left: inout [Double], _ right: inout [Double]) -> GlueStats {
        let n = left.count
        var detector = [Double](repeating: -120, count: n)
        var meanSquare = 0.0
        let smoothing = 1 - exp(-1 / (0.01 * sampleRate))
        for i in 0..<n {
            meanSquare += smoothing * (0.5 * (left[i] * left[i] + right[i] * right[i]) - meanSquare)
            detector[i] = 10 * log10(meanSquare + 1e-12)
        }
        var levels: [Double] = []
        var i = 0
        while i < n {
            if detector[i] > -50 {
                levels.append(detector[i])
            }
            i += 64
        }
        levels.sort()
        let p90 = levels.isEmpty ? -20 : levels[Int(0.9 * Double(levels.count - 1))]
        let threshold = p90 - 5
        let ratio = 2.0
        let knee = 6.0
        let slope = 1 - 1 / ratio
        let attack = 1 - exp(-1 / (0.02 * sampleRate))
        let release = 1 - exp(-1 / (0.22 * sampleRate))
        var reduction = 0.0
        var activeSum = 0.0
        var activeCount = 0
        var loudSum = 0.0
        var loudCount = 0
        var maxReduction = 0.0
        for k in 0..<n {
            let over = detector[k] - threshold
            let target: Double
            if over <= -knee / 2 {
                target = 0
            } else if over < knee / 2 {
                target = -slope * (over + knee / 2) * (over + knee / 2) / (2 * knee)
            } else {
                target = -slope * over
            }
            reduction += (target - reduction) * (target < reduction ? attack : release)
            let g = pow(10, reduction / 20)
            left[k] *= g
            right[k] *= g
            if detector[k] > -50 {
                activeSum += reduction
                activeCount += 1
            }
            if detector[k] > p90 - 3 {
                loudSum += reduction
                loudCount += 1
            }
            maxReduction = min(maxReduction, reduction)
        }
        return GlueStats(thresholdDbfs: threshold, ratio: ratio,
                         averageReductionDb: activeCount > 0 ? -activeSum / Double(activeCount) : 0,
                         loudReductionDb: loudCount > 0 ? -loudSum / Double(loudCount) : 0,
                         maxReductionDb: -maxReduction)
    }

    /// tanh(d x) / d at twice the sample rate with linear-phase half-band
    /// filters, so the added harmonics cannot fold back.
    static func saturate(_ left: inout [Double], _ right: inout [Double], drive: Double) {
        let half = 23
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
        // Odd-offset half-band taps h(d) for d = 2k - 1, k = -11 ... 12.
        var odd = [Double](repeating: 0, count: 24)
        for k in -11...12 {
            let d = Double(2 * k - 1)
            let sinc = sin(Double.pi * d / 2) / (Double.pi * d / 2)
            let r = d / Double(half + 1)
            odd[k + 11] = 0.5 * sinc * besselI0(beta * max(0, 1 - r * r).squareRoot()) / besselI0(beta)
        }
        let oddSum = odd.reduce(0, +)
        let up = odd.map { $0 / oddSum }
        let down = odd.map { $0 * 0.5 / oddSum }
        func shape(_ x: Double) -> Double {
            tanh(drive * x) / drive
        }
        func process(_ x: inout [Double]) {
            let n = x.count
            var even = [Double](repeating: 0, count: n)
            var mid = [Double](repeating: 0, count: n)
            for m in 0..<n {
                even[m] = shape(x[m])
                var acc = 0.0
                for k in -11...12 {
                    let j = m + k
                    if j >= 0 && j < n {
                        acc += up[k + 11] * x[j]
                    }
                }
                mid[m] = shape(acc)
            }
            for m in 0..<n {
                var acc = 0.5 * even[m]
                for k in -11...12 {
                    let j = m + k - 1
                    if j >= 0 && j < n {
                        acc += down[k + 11] * mid[j]
                    }
                }
                x[m] = acc
            }
        }
        process(&left)
        process(&right)
    }

    /// Lookahead limiter on the 4x true peak: a held minimum of the required
    /// gain, two box smoothers (about 3 ms of attack in total) that stay under
    /// the requirement everywhere, then an 80 ms release.
    static func limit(_ left: inout [Double], _ right: inout [Double], ceiling: Double) -> LimiterStats {
        let n = left.count
        let lookahead = 72
        let holdLength = 2 * lookahead
        let required = TruePeak.requiredGain(left, right, ceiling: ceiling)
        var hold = [Double](repeating: 1, count: n)
        for m in 0..<n where required[m] < 1 {
            for k in max(0, m - holdLength)...m {
                hold[k] = min(hold[k], required[m])
            }
        }
        // Only the neighborhoods of gain reduction need the smoothers.
        var touched = [Bool](repeating: false, count: n)
        for m in 0..<n where hold[m] < 1 {
            for k in m..<min(n, m + 2 * lookahead) {
                touched[k] = true
            }
        }
        var first = [Double](repeating: 1, count: n)
        var second = [Double](repeating: 1, count: n)
        for m in 0..<n where touched[m] {
            var sum = 0.0
            for k in (m - lookahead + 1)...m {
                sum += k >= 0 ? hold[k] : 1
            }
            first[m] = sum / Double(lookahead)
        }
        for m in 0..<n where touched[m] {
            var sum = 0.0
            for k in (m - lookahead + 1)...m {
                sum += k >= 0 ? first[k] : 1
            }
            second[m] = sum / Double(lookahead)
        }
        let releaseCoefficient = 1 - exp(-1 / (0.08 * sampleRate))
        var g = 1.0
        var maxReduction = 1.0
        var limited = 0
        for m in 0..<n {
            let target = second[m]
            if target < g {
                g = target
            } else {
                g += (target - g) * releaseCoefficient
            }
            if g < 0.9999 {
                limited += 1
            }
            maxReduction = min(maxReduction, g)
            left[m] *= g
            right[m] *= g
        }
        return LimiterStats(ceilingDbtp: gainToDb(ceiling), maxReductionDb: -gainToDb(maxReduction),
                            limitedMilliseconds: Double(limited) / sampleRate * 1000)
    }

    /// A 5 ms declick at the start and a 0.3 s fade at the end.
    static func fades(_ left: inout [Double], _ right: inout [Double]) {
        let n = left.count
        let head = min(n, sampleIndex(0.005))
        for i in 0..<head {
            let g = raisedCosine(Double(i) / Double(head))
            left[i] *= g
            right[i] *= g
        }
        let tail = min(n, sampleIndex(0.3))
        for i in 0..<tail {
            let k = n - tail + i
            let g = 1 - raisedCosine(Double(i + 1) / Double(tail))
            left[k] *= g
            right[k] *= g
        }
    }

    static func quantize(_ x: [Double]) -> [Int32] {
        x.map { Int32(clamp(($0 * fullScale).rounded(), -fullScale, fullScale - 1)) }
    }
}
