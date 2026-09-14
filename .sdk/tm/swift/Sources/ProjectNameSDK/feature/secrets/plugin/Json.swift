// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Json.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// The JSON parser.
///
/// A hundred and fifty lines, and a hundred and fifty lines is cheaper than an
/// `import Foundation` in a library whose whole value model is an enum
/// `JSONSerialization` cannot produce.
public enum Json {

    public static func parse(_ text: String) throws -> Value {
        var parser = Parser(Array(text.unicodeScalars))
        parser.skipws()
        let value = try parser.value()
        parser.skipws()
        if parser.at < parser.chars.count {
            throw PluginError("plugin_json", "trailing input at \(parser.at)", [:])
        }
        return value
    }

    struct Parser {
        let chars: [Unicode.Scalar]
        var at: Int = 0

        init(_ chars: [Unicode.Scalar]) { self.chars = chars }

        mutating func skipws() {
            while at < chars.count,
                  chars[at] == " " || chars[at] == "\t" ||
                  chars[at] == "\n" || chars[at] == "\r" {
                at += 1
            }
        }

        mutating func value() throws -> Value {
            guard at < chars.count else {
                throw PluginError("plugin_json", "unexpected end of input", [:])
            }
            switch chars[at] {
            case "{": return try map()
            case "[": return try list()
            case "\"": return .str(try string())
            case "t": return try literal("true", .bool(true))
            case "f": return try literal("false", .bool(false))
            case "n": return try literal("null", .null)
            default: return try number()
            }
        }

        mutating func literal(_ word: String, _ value: Value) throws -> Value {
            let scalars = Array(word.unicodeScalars)
            guard at + scalars.count <= chars.count,
                  Array(chars[at ..< at + scalars.count]) == scalars else {
                throw PluginError("plugin_json", "unexpected input at \(at)", [:])
            }
            at += scalars.count
            return value
        }

        mutating func map() throws -> Value {
            var out: [String: Value] = [:]
            at += 1
            skipws()
            if at < chars.count, chars[at] == "}" {
                at += 1
                return .map(out)
            }
            while true {
                skipws()
                let key = try string()
                skipws()
                guard at < chars.count, chars[at] == ":" else {
                    throw PluginError("plugin_json", "expected : at \(at)", [:])
                }
                at += 1
                skipws()
                out[key] = try value()
                skipws()
                guard at < chars.count else {
                    throw PluginError("plugin_json", "unterminated map", [:])
                }
                if chars[at] == "," { at += 1; continue }
                guard chars[at] == "}" else {
                    throw PluginError("plugin_json", "expected } at \(at)", [:])
                }
                at += 1
                return .map(out)
            }
        }

        mutating func list() throws -> Value {
            var out: [Value] = []
            at += 1
            skipws()
            if at < chars.count, chars[at] == "]" {
                at += 1
                return .list(out)
            }
            while true {
                skipws()
                out.append(try value())
                skipws()
                guard at < chars.count else {
                    throw PluginError("plugin_json", "unterminated list", [:])
                }
                if chars[at] == "," { at += 1; continue }
                guard chars[at] == "]" else {
                    throw PluginError("plugin_json", "expected ] at \(at)", [:])
                }
                at += 1
                return .list(out)
            }
        }

        mutating func string() throws -> String {
            guard at < chars.count, chars[at] == "\"" else {
                throw PluginError("plugin_json", "expected string at \(at)", [:])
            }
            at += 1
            var out = String.UnicodeScalarView()
            while true {
                guard at < chars.count else {
                    throw PluginError("plugin_json", "unterminated string", [:])
                }
                let c = chars[at]
                if c == "\"" {
                    at += 1
                    return String(out)
                }
                if c == "\\" {
                    at += 1
                    guard at < chars.count else {
                        throw PluginError("plugin_json", "unterminated escape", [:])
                    }
                    switch chars[at] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append(Unicode.Scalar(8))
                    case "f": out.append(Unicode.Scalar(12))
                    case "u":
                        var code: UInt32 = 0
                        for k in 1 ... 4 {
                            guard at + k < chars.count,
                                  let digit = chars[at + k].hexDigitValue else {
                                throw PluginError("plugin_json", "bad \\u escape", [:])
                            }
                            code = code * 16 + UInt32(digit)
                        }
                        guard let scalar = Unicode.Scalar(code) else {
                            throw PluginError("plugin_json", "bad \\u escape", [:])
                        }
                        out.append(scalar)
                        at += 4
                    default: out.append(chars[at])
                    }
                    at += 1
                    continue
                }
                out.append(c)
                at += 1
            }
        }

        mutating func number() throws -> Value {
            let start = at
            while at < chars.count, Json.isNumeric(chars[at]) { at += 1 }
            guard start != at, let n = Double(String(String.UnicodeScalarView(chars[start ..< at])))
            else {
                throw PluginError("plugin_json", "unexpected input at \(at)", [:])
            }
            return .num(n)
        }
    }

    static func isNumeric(_ c: Unicode.Scalar) -> Bool {
        return ("0" ... "9").contains(c) ||
            c == "-" || c == "+" || c == "." || c == "e" || c == "E"
    }
}

extension Unicode.Scalar {
    var hexDigitValue: Int? {
        switch self {
        case "0" ... "9": return Int(value - 48)
        case "a" ... "f": return Int(value - 87)
        case "A" ... "F": return Int(value - 55)
        default: return nil
        }
    }
}
