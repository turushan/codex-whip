import Foundation

/// A JSON value that keeps the distinctions the engine relies on: an integer is not a float,
/// a boolean is not a number, and an object can be checked for duplicate keys.
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        get {
            if case .object(let value) = self { return value[key] }
            return nil
        }
        set {
            guard case .object(var value) = self else { return }
            value[key] = newValue
            self = .object(value)
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    /// Integers and floats as a finite or infinite Double; booleans are not numbers.
    public var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var array: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// A nonempty string, matching Python's truthiness for identifiers.
    public var nonemptyString: String? {
        guard let value = string, !value.isEmpty else { return nil }
        return value
    }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
                ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSON {
    public init(_ value: String?) { self = value.map(JSON.string) ?? .null }
    public init(_ value: Double?) { self = value.map(JSON.double) ?? .null }
    public init(_ value: Bool?) { self = value.map(JSON.bool) ?? .null }
}

public struct JSONError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - Parsing

extension JSON {
    /// Parses UTF-8 JSON. `rejectDuplicateKeys` refuses objects that repeat a key, and
    /// non-finite constants such as NaN are always refused.
    public static func parse(_ data: Data, rejectDuplicateKeys: Bool = false, maxDepth: Int = 512) throws -> JSON {
        var parser = Parser(bytes: [UInt8](data), rejectDuplicates: rejectDuplicateKeys, maxDepth: maxDepth)
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw JSONError("Extra data after JSON value") }
        return value
    }

    public static func parse(_ text: String, rejectDuplicateKeys: Bool = false) throws -> JSON {
        try parse(Data(text.utf8), rejectDuplicateKeys: rejectDuplicateKeys)
    }

    private struct Parser {
        let bytes: [UInt8]
        let rejectDuplicates: Bool
        let maxDepth: Int
        var index = 0

        init(bytes: [UInt8], rejectDuplicates: Bool, maxDepth: Int) {
            self.bytes = bytes
            self.rejectDuplicates = rejectDuplicates
            self.maxDepth = maxDepth
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> JSON {
            guard depth <= maxDepth else { throw JSONError("JSON nesting is too deep") }
            guard index < bytes.count else { throw JSONError("Unexpected end of JSON") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ text: String) throws {
            let expected = Array(text.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<index + expected.count]) == expected else {
                throw JSONError("Invalid JSON literal")
            }
            index += expected.count
        }

        mutating func object(depth: Int) throws -> JSON {
            index += 1
            var result: [String: JSON] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(result) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw JSONError("Expected object key") }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw JSONError("Expected ':'") }
                index += 1
                skipWhitespace()
                let item = try value(depth: depth + 1)
                if rejectDuplicates && result[key] != nil { throw JSONError("Duplicate message field") }
                result[key] = item
                skipWhitespace()
                guard index < bytes.count else { throw JSONError("Unexpected end of JSON") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(result) }
                throw JSONError("Expected ',' or '}'")
            }
        }

        mutating func array(depth: Int) throws -> JSON {
            index += 1
            var result: [JSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(result) }
            while true {
                skipWhitespace()
                result.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw JSONError("Unexpected end of JSON") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(result) }
                throw JSONError("Expected ',' or ']'")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw JSONError("Invalid unicode escape") }
            var value: UInt32 = 0
            for byte in bytes[index..<index + 4] {
                value <<= 4
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): value |= UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): value |= UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): value |= UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw JSONError("Invalid unicode escape")
                }
            }
            index += 4
            return value
        }

        mutating func string() throws -> String {
            index += 1
            var output = [UInt8]()
            while true {
                guard index < bytes.count else { throw JSONError("Unterminated string") }
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\"") { break }
                if byte < 0x20 { throw JSONError("Invalid control character in string") }
                if byte != UInt8(ascii: "\\") { output.append(byte); continue }
                guard index < bytes.count else { throw JSONError("Unterminated string") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): output.append(0x22)
                case UInt8(ascii: "\\"): output.append(0x5C)
                case UInt8(ascii: "/"): output.append(0x2F)
                case UInt8(ascii: "b"): output.append(0x08)
                case UInt8(ascii: "f"): output.append(0x0C)
                case UInt8(ascii: "n"): output.append(0x0A)
                case UInt8(ascii: "r"): output.append(0x0D)
                case UInt8(ascii: "t"): output.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar), index + 6 <= bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let saved = index
                        index += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = saved
                        }
                    }
                    // A lone surrogate becomes U+FFFD, as Swift strings cannot hold it.
                    let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    output.append(contentsOf: Array(String(character).utf8))
                default: throw JSONError("Invalid string escape")
                }
            }
            guard let text = String(bytes: output, encoding: .utf8) else { throw JSONError("Invalid UTF-8 in string") }
            return text
        }

        mutating func number() throws -> JSON {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
                throw JSONError("Invalid JSON value")
            }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            }
            var isFloat = false
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                isFloat = true
                index += 1
                let digits = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                guard index > digits else { throw JSONError("Invalid number") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                isFloat = true
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                let digits = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                guard index > digits else { throw JSONError("Invalid number") }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if !isFloat, let value = Int(text) { return .int(value) }
            guard let value = Double(text) else { throw JSONError("Invalid number") }
            return .double(value)
        }
    }
}

// MARK: - Serialization

extension JSON {
    public struct Format: Sendable {
        public var sortKeys = true
        /// Escape every non-ASCII character as \uXXXX, as Python's json.dumps does by default.
        public var asciiOnly = false
        public var indent: Int? = nil
        public static let compact = Format()
        public static let pretty = Format(indent: 2)
        public static let ascii = Format(asciiOnly: true)

        public init(sortKeys: Bool = true, asciiOnly: Bool = false, indent: Int? = nil) {
            self.sortKeys = sortKeys
            self.asciiOnly = asciiOnly
            self.indent = indent
        }
    }

    /// Fails for non-finite floats, which JSON cannot represent.
    public func serialized(_ format: Format = .compact) throws -> String {
        var output = ""
        try write(into: &output, format: format, level: 0)
        return output
    }

    public func data(_ format: Format = .compact) throws -> Data {
        Data(try serialized(format).utf8)
    }

    private func write(into output: inout String, format: Format, level: Int) throws {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .int(let value): output += String(value)
        case .double(let value):
            guard value.isFinite else { throw JSONError("Nonfinite JSON number") }
            output += JSON.formatDouble(value)
        case .string(let value): JSON.writeString(value, into: &output, asciiOnly: format.asciiOnly)
        case .array(let values):
            if values.isEmpty { output += "[]"; return }
            output += "["
            for (offset, value) in values.enumerated() {
                if offset > 0 { output += "," }
                newline(&output, format: format, level: level + 1)
                try value.write(into: &output, format: format, level: level + 1)
            }
            newline(&output, format: format, level: level)
            output += "]"
        case .object(let values):
            if values.isEmpty { output += "{}"; return }
            output += "{"
            let keys = format.sortKeys ? values.keys.sorted() : Array(values.keys)
            for (offset, key) in keys.enumerated() {
                if offset > 0 { output += "," }
                newline(&output, format: format, level: level + 1)
                JSON.writeString(key, into: &output, asciiOnly: format.asciiOnly)
                output += format.indent == nil ? ":" : ": "
                try values[key]!.write(into: &output, format: format, level: level + 1)
            }
            newline(&output, format: format, level: level)
            output += "}"
        }
    }

    private func newline(_ output: inout String, format: Format, level: Int) {
        guard let indent = format.indent else { return }
        output += "\n" + String(repeating: " ", count: indent * level)
    }

    /// Python's repr for floats: whole numbers keep ".0", and other values use the shortest form.
    static func formatDouble(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e16 {
            return String(format: "%.1f", value)
        }
        return "\(value)"
    }

    private static func writeString(_ value: String, into output: inout String, asciiOnly: Bool) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else if asciiOnly && scalar.value > 0x7E {
                    for unit in String(scalar).utf16 { output += String(format: "\\u%04x", unit) }
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

// MARK: - Codable

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSON].self) { self = .array(value); return }
        self = .object(try container.decode([String: JSON].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
