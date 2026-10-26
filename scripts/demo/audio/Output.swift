import Foundation

// File output: SHA-256 (FIPS 180-4), 24-bit PCM WAV, and an ordered JSON writer.

enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 {
            data.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        var w = [UInt32](repeating: 0, count: 64)
        data.withUnsafeBufferPointer { bytes in
            var chunk = 0
            while chunk < bytes.count {
                for t in 0..<16 {
                    let i = chunk + 4 * t
                    w[t] = UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
                }
                for t in 16..<64 {
                    let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                    let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                    w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
                }
                var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
                for t in 0..<64 {
                    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let temp1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
                    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let temp2 = s0 &+ maj
                    hh = g
                    g = f
                    f = e
                    e = d &+ temp1
                    d = c
                    c = b
                    b = a
                    a = temp1 &+ temp2
                }
                h[0] = h[0] &+ a
                h[1] = h[1] &+ b
                h[2] = h[2] &+ c
                h[3] = h[3] &+ d
                h[4] = h[4] &+ e
                h[5] = h[5] &+ f
                h[6] = h[6] &+ g
                h[7] = h[7] &+ hh
                chunk += 64
            }
        }
        var out: [UInt8] = []
        for value in h {
            out += [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        }
        return out
    }

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    static func hex(_ message: [UInt8]) -> String {
        digest(message).map { String(format: "%02x", $0) }.joined()
    }
}

enum WAV {
    /// Interleaved stereo, 24-bit little-endian PCM at 48 kHz.
    static func encode(left: [Int32], right: [Int32]) -> [UInt8] {
        let frames = left.count
        let dataSize = frames * 6
        var bytes = [UInt8](repeating: 0, count: 44 + dataSize)
        func put(_ text: String, _ at: Int) {
            for (i, c) in text.utf8.enumerated() {
                bytes[at + i] = c
            }
        }
        func put32(_ value: UInt32, _ at: Int) {
            for i in 0..<4 {
                bytes[at + i] = UInt8((value >> (8 * UInt32(i))) & 0xff)
            }
        }
        func put16(_ value: UInt16, _ at: Int) {
            bytes[at] = UInt8(value & 0xff)
            bytes[at + 1] = UInt8(value >> 8)
        }
        put("RIFF", 0)
        put32(UInt32(36 + dataSize), 4)
        put("WAVE", 8)
        put("fmt ", 12)
        put32(16, 16)
        put16(1, 20)
        put16(2, 22)
        put32(48_000, 24)
        put32(48_000 * 6, 28)
        put16(6, 32)
        put16(24, 34)
        put("data", 36)
        put32(UInt32(dataSize), 40)
        bytes.withUnsafeMutableBufferPointer { out in
            var p = 44
            for i in 0..<frames {
                let l = UInt32(bitPattern: left[i])
                let r = UInt32(bitPattern: right[i])
                out[p] = UInt8(l & 0xff)
                out[p + 1] = UInt8((l >> 8) & 0xff)
                out[p + 2] = UInt8((l >> 16) & 0xff)
                out[p + 3] = UInt8(r & 0xff)
                out[p + 4] = UInt8((r >> 8) & 0xff)
                out[p + 5] = UInt8((r >> 16) & 0xff)
                p += 6
            }
        }
        return bytes
    }

    static func write(_ bytes: [UInt8], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }
}

/// JSON value with insertion-ordered objects and fixed decimal places.
indirect enum JSON {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    case number(Double, Int)
    case integer(Int)
    case bool(Bool)
    case null

    func rendered(_ indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let pairs):
            if pairs.isEmpty {
                return "{}"
            }
            let body = pairs.map { "\(inner)\(JSON.quote($0.0)): \($0.1.rendered(indent + 1))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(pad)}"
        case .array(let items):
            if items.isEmpty {
                return "[]"
            }
            let scalar = items.allSatisfy {
                if case .object = $0 { return false }
                if case .array = $0 { return false }
                return true
            }
            if scalar {
                return "[" + items.map { $0.rendered(indent + 1) }.joined(separator: ", ") + "]"
            }
            return "[\n" + items.map { inner + $0.rendered(indent + 1) }.joined(separator: ",\n") + "\n\(pad)]"
        case .string(let text):
            return JSON.quote(text)
        case .number(let value, let decimals):
            guard value.isFinite else { return "null" }
            let text = String(format: "%.\(decimals)f", value)
            return text == "-0" || text.hasPrefix("-0.") && Double(text) == 0 ? String(text.dropFirst()) : text
        case .integer(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
