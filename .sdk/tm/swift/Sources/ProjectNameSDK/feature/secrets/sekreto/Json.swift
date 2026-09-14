// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/src/Json.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Minimal JSON support for sekreto.
//
// sekreto adds no third-party dependencies, so it carries just enough JSON
// to read a vault's answer and write the CLI's own line of output. It is
// deliberately not a general-purpose library.
//
// Hand-rolled rather than JSONSerialization, for two reasons that both
// matter here. JSONSerialization hands back an unordered Dictionary, and a
// signed payload's field order is part of what was signed; and it bridges
// numbers through NSNumber, where `true` and `1` are not reliably
// distinguishable. An `enum` keeps a vault answering `null`, `false`, `0`
// and "no such key" as four different things at compile time rather than
// by convention.
//
// `parse` returns `Json?`, where `nil` means "this text is not JSON" and
// `.null` means "this text is the JSON literal null" - a distinction the
// plugins' HTTP round-trip needs, since only the first is a malformed
// response. It stays in the core because the core writes JSON too: a
// Sekreto describes itself as data, without its secrets.
//
// A port of typescript/src/Json.ts, which is canonical.

import Foundation

/// An insertion-ordered map.
///
/// Swift's `Dictionary` is unordered, and three things here are compared or
/// signed as whole maps: a memory provider's `values`, the SigV4 output
/// headers, and a `.env` file's contents. A pair list keeps the order the
/// author wrote, at a lookup cost that is irrelevant at these sizes.
public struct Ordered<Value> {

  public private(set) var pairs: [(String, Value)] = []

  public init() {}

  public init(_ entries: [(String, Value)]) {
    for (key, value) in entries {
      self[key] = value
    }
  }

  /// Read or write one entry. Assigning an existing key keeps its position.
  public subscript(key: String) -> Value? {
    get {
      for (entrykey, value) in pairs where entrykey == key {
        return value
      }
      return nil
    }
    set {
      let at = pairs.firstIndex { $0.0 == key }
      if let newvalue = newValue {
        if let at = at {
          pairs[at] = (key, newvalue)
        } else {
          pairs.append((key, newvalue))
        }
      } else if let at = at {
        pairs.remove(at: at)
      }
    }
  }

  public var keys: [String] { return pairs.map { $0.0 } }

  public var values: [Value] { return pairs.map { $0.1 } }

  public var count: Int { return pairs.count }

  public var isEmpty: Bool { return pairs.isEmpty }
}

/// A JSON value.
public indirect enum Json {

  case null
  case bool(Bool)
  case num(Double)
  case str(String)
  case list([Json])
  case map(Ordered<Json>)

  public var asstr: String? {
    if case .str(let value) = self { return value }
    return nil
  }

  public var asnum: Double? {
    if case .num(let value) = self { return value }
    return nil
  }

  public var asbool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var aslist: [Json]? {
    if case .list(let value) = self { return value }
    return nil
  }

  public var asmap: Ordered<Json>? {
    if case .map(let value) = self { return value }
    return nil
  }

  /// Walk nested objects; nil the moment a step is not there.
  public func dig(_ keys: String...) -> Json? {
    return digall(keys)
  }

  public func digall(_ keys: [String]) -> Json? {
    var at: Json? = self

    for key in keys {
      guard let here = at, case .map(let entries) = here else { return nil }
      at = entries[key]
    }

    return at
  }

  /// This value as the text a caller would print, or nil when there is no
  /// value at all. A JSON null is "no value": every provider here treats it
  /// as a miss rather than as the string "null".
  public var text: String? {
    switch self {
    case .null: return nil
    case .str(let value): return value
    case .num(let value): return numstr(value)
    case .bool(let value): return value ? "true" : "false"
    default: return Json.stringify(self)
    }
  }

  // ---- constructors ----

  public static func obj(_ entries: [(String, Json)]) -> Json {
    return .map(Ordered(entries))
  }

  // ---- writing ----

  /// Render a value as compact JSON.
  public static func stringify(_ value: Json) -> String {
    var out = ""
    write(value, &out)
    return out
  }

  /// Render a string as a JSON string literal, quotes included.
  public static func quote(_ text: String) -> String {
    var out = "\""

    for ch in text.unicodeScalars {
      switch ch {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if 0x20 > ch.value {
          out += String(format: "\\u%04x", ch.value)
        } else {
          out.unicodeScalars.append(ch)
        }
      }
    }

    return out + "\""
  }

  private static func write(_ value: Json, _ out: inout String) {
    switch value {
    case .null:
      out += "null"
    case .bool(let entry):
      out += entry ? "true" : "false"
    case .num(let entry):
      out += numstr(entry)
    case .str(let entry):
      out += quote(entry)
    case .list(let entries):
      out += "["
      for (index, entry) in entries.enumerated() {
        if 0 < index { out += "," }
        write(entry, &out)
      }
      out += "]"
    case .map(let entries):
      out += "{"
      for (index, pair) in entries.pairs.enumerated() {
        if 0 < index { out += "," }
        out += quote(pair.0) + ":"
        write(pair.1, &out)
      }
      out += "}"
    }
  }

  // ---- reading ----

  /// Parse JSON text. nil for anything unreadable - which the caller must
  /// tell apart from a literal `null` body, since only the first means the
  /// store could not answer coherently.
  public static func parse(_ text: String?) -> Json? {
    guard let text = text, !text.isEmpty else { return nil }

    var reader = Reader(Array(text))
    reader.skip()

    guard let value = reader.value(0) else { return nil }

    reader.skip()
    if !reader.done { return nil }

    return value
  }

  /// A recursive-descent reader that answers nil rather than raising: no
  /// error escapes `parse`, because a response body arrives before any
  /// trust check has been made of it.
  private struct Reader {

    // A response body arrives before anything has vouched for it, so the
    // nesting depth is bounded: `[[[[...` must not take the process down
    // with a stack overflow.
    static let MAXDEPTH = 128

    let text: [Character]
    var at: Int = 0

    init(_ text: [Character]) {
      self.text = text
    }

    var done: Bool { return at >= text.count }

    mutating func skip() {
      while !done {
        let ch = text[at]
        if " " == ch || "\t" == ch || "\n" == ch || "\r" == ch {
          at += 1
        } else {
          break
        }
      }
    }

    mutating func value(_ depth: Int) -> Json? {
      if Reader.MAXDEPTH < depth { return nil }
      if done { return nil }

      switch text[at] {
      case "{": return obj(depth)
      case "[": return arr(depth)
      case "\"":
        guard let entry = str() else { return nil }
        return .str(entry)
      case "t":
        return word("true") ? .bool(true) : nil
      case "f":
        return word("false") ? .bool(false) : nil
      case "n":
        return word("null") ? Json.null : nil
      default: return num()
      }
    }

    /// A literal is matched WHOLE: `tru` and `nullx` are not values.
    mutating func word(_ want: String) -> Bool {
      for expect in want {
        guard !done, text[at] == expect else { return false }
        at += 1
      }
      return true
    }

    mutating func obj(_ depth: Int) -> Json? {
      var out = Ordered<Json>()
      at += 1  // {

      skip()
      if !done, "}" == text[at] {
        at += 1
        return .map(out)
      }

      while true {
        skip()
        guard let key = str() else { return nil }
        skip()

        guard !done, ":" == text[at] else { return nil }
        at += 1

        skip()
        guard let entry = value(depth + 1) else { return nil }
        out[key] = entry
        skip()

        if done { return nil }
        if "," == text[at] {
          at += 1
          continue
        }
        if "}" == text[at] {
          at += 1
          return .map(out)
        }
        return nil
      }
    }

    mutating func arr(_ depth: Int) -> Json? {
      var out: [Json] = []
      at += 1  // [

      skip()
      if !done, "]" == text[at] {
        at += 1
        return .list(out)
      }

      while true {
        skip()
        guard let entry = value(depth + 1) else { return nil }
        out.append(entry)
        skip()

        if done { return nil }
        if "," == text[at] {
          at += 1
          continue
        }
        if "]" == text[at] {
          at += 1
          return .list(out)
        }
        return nil
      }
    }

    mutating func str() -> String? {
      guard !done, "\"" == text[at] else { return nil }
      at += 1

      var out = ""

      while !done {
        let ch = text[at]
        at += 1

        if "\"" == ch { return out }

        if "\\" != ch {
          out.append(ch)
          continue
        }

        if done { return nil }
        let escape = text[at]
        at += 1

        switch escape {
        case "\"": out.append("\"")
        case "\\": out.append("\\")
        case "/": out.append("/")
        case "b": out.append("\u{8}")
        case "f": out.append("\u{c}")
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "u":
          guard at + 4 <= text.count else { return nil }
          let digits = String(text[at..<(at + 4)])
          at += 4
          guard let code = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(code) else {
            return nil
          }
          out.append(Character(scalar))
        default: return nil
        }
      }

      return nil
    }

    mutating func num() -> Json? {
      let start = at

      if !done, "-" == text[at] || "+" == text[at] { at += 1 }

      while !done {
        let ch = text[at]
        if ch.isNumber || "." == ch || "e" == ch || "E" == ch || "-" == ch || "+" == ch {
          at += 1
        } else {
          break
        }
      }

      let span = String(text[start..<at])

      // `1e999` parses to infinity, which JSON has no notation for and
      // which would later blow up a token-expiry computation.
      guard let value = Double(span), value.isFinite else { return nil }

      return .num(value)
    }
  }
}

/// The same reads on an optional value, so a provider can walk a response
/// body - which is `Json?`, because a store may not have answered with JSON
/// at all - without unwrapping at every step.
extension Optional where Wrapped == Json {

  public func dig(_ keys: String...) -> Json? {
    return self?.digall(keys)
  }

  public var text: String? { return self?.text }

  public var asstr: String? { return self?.asstr }

  public var asnum: Double? { return self?.asnum }

  public var asbool: Bool? { return self?.asbool }

  public var aslist: [Json]? { return self?.aslist }

  public var asmap: Ordered<Json>? { return self?.asmap }
}

/// Render a number the way every other port does: a whole number has no
/// fractional tail, so a JSON `1` read back and printed stays `1`.
public func numstr(_ value: Double) -> String {
  if value.isNaN || value.isInfinite { return "null" }

  if value == value.rounded(.towardZero) && 9_007_199_254_740_992.0 > abs(value) {
    return String(Int64(value))
  }

  return String(value)
}
