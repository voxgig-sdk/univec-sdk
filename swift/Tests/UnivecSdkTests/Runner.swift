// Univec SDK test runner - shared infrastructure for the generated test
// suites. Because the SDK's loose model IS the struct Value, the corpus loads
// directly to Value (no conversion) and comparisons use a canonical
// sorted-key JSON with .noval/.null unification.

import XCTest

@testable import UnivecSdk

enum SdkRunner {
  // The shared SDK test spec lives at <project>/.sdk/test/test.json, i.e. up
  // three dirs from this file (swift/Tests/UnivecSDKTests -> project).
  static func testJsonPath(_ file: String = #filePath) -> String {
    let dir = URL(fileURLWithPath: file)
      .deletingLastPathComponent()  // UnivecSDKTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .deletingLastPathComponent()  // project (holds .sdk)
    return dir.appendingPathComponent(".sdk").appendingPathComponent("test")
      .appendingPathComponent("test.json").path
  }

  static func loadAll() -> Value {
    let text = (try? String(contentsOfFile: testJsonPath(), encoding: .utf8)) ?? "{}"
    return (try? JSON.parse(text)) ?? .map(VMap())
  }

  static func loadPrimary() -> Value { getprop(loadAll(), .string("primary")) }

  static func spec(_ v: Value, _ keys: String...) -> Value {
    var cur = v
    for k in keys { cur = getprop(cur, .string(k)) }
    return cur
  }

  // Canonical sorted-key JSON with .noval/.null unification for comparison.
  static func canon(_ v: Value) -> String { stringify(normaliseAbsent(v)) }

  private static func normaliseAbsent(_ v: Value) -> Value {
    switch v {
    case .noval: return .null
    case .list(let l): return .list(l.items.map { normaliseAbsent($0) })
    case .map(let m):
      let nm = VMap()
      for (k, vv) in m.entries { nm.entries[k] = normaliseAbsent(vv) }
      return .map(nm)
    default: return v
    }
  }

  static func deepEqual(_ a: Value, _ b: Value) -> Bool { canon(a) == canon(b) }

  static func errCode(_ e: Error?) -> String {
    (e as? UnivecError)?.code ?? ""
  }

  // matchString: /regex/ or case-insensitive contains.
  static func matchString(_ pattern: String, _ val: String) -> Bool {
    if pattern.count >= 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
      let inner = String(pattern.dropFirst().dropLast())
      if let re = try? NSRegularExpression(pattern: inner) {
        return re.firstMatch(in: val, range: NSRange(val.startIndex..., in: val)) != nil
      }
      return false
    }
    return val.lowercased().contains(pattern.lowercased())
  }

  // matchDeep: recursively assert `check` against `base` (subset match).
  static func matchDeep(_ idx: Int, _ check: Value, _ base: Value, _ path: String) {
    switch check {
    case .map(let cm):
      for (k, cv) in cm.entries {
        let childBase = base.asMap?.entries[k] ?? .noval
        matchDeep(idx, cv, childBase, path + "." + k)
      }
    case .list(let cl):
      let bl = base.asList
      for (i, cv) in cl.items.enumerated() {
        let childBase = (bl != nil && i < bl!.items.count) ? bl!.items[i] : .noval
        matchDeep(idx, cv, childBase, "\(path)[\(i)]")
      }
    default:
      if case .string(let cs) = check {
        if cs == "__EXISTS__" {
          XCTAssertFalse(isNil(base), "entry \(idx): match \(path): expected value to exist")
          return
        }
        if cs == "__UNDEF__" {
          XCTAssertTrue(isNil(base), "entry \(idx): match \(path): expected absent, got \(canon(base))")
          return
        }
      }
      if !deepEqual(check, base) {
        if case .string(let cs) = check, cs != "", matchString(cs, stringify(base)) { return }
        XCTFail("entry \(idx): match \(path): got \(canon(base)), want \(canon(check))")
      }
    }
  }

  // runSet: drive a primary test set. `subject` returns (result, thrownError)
  // and may mutate `entry` (e.g. record produced ctx state under "ctx").
  static func runSet(_ testspec: Value, _ subject: (VMap) throws -> Value) {
    guard let set = testspec.asMap?.entries["set"]?.asList else { return }
    for (i, entryV) in set.items.enumerated() {
      guard let entry = entryV.asMap else { continue }
      let mark = entry.entries["mark"].map { " (mark=\(stringify($0)))" } ?? ""

      var result: Value = .noval
      var err: Error? = nil
      do { result = try subject(entry) } catch { err = error }

      let expectedErr = entry.entries["err"]

      if let err = err {
        if let expectedErr = expectedErr {
          if case .string(let expStr) = expectedErr {
            XCTAssertTrue(matchString(expStr, errMessage(err)),
              "entry \(i)\(mark): error mismatch: got \"\(errMessage(err))\" want contains \"\(expStr)\"")
          }
          if let matchSpec = entry.entries["match"]?.asMap {
            let rm = VMap()
            rm.entries["in"] = entry.entries["in"] ?? .noval
            rm.entries["out"] = result
            let em = VMap(); em.entries["message"] = .string(errMessage(err))
            rm.entries["err"] = .map(em)
            matchDeep(i, .map(matchSpec), .map(rm), "")
          }
          continue
        }
        XCTFail("entry \(i)\(mark): unexpected error: \(errMessage(err))")
        continue
      }

      if let expectedErr = expectedErr {
        XCTFail("entry \(i)\(mark): expected error \(canon(expectedErr)) but got \(canon(result))")
        continue
      }

      var matched = false
      if let matchSpec = entry.entries["match"]?.asMap {
        let rm = VMap()
        rm.entries["in"] = entry.entries["in"] ?? .noval
        rm.entries["out"] = result
        if let args = entry.entries["args"] {
          rm.entries["args"] = args
        } else if let inv = entry.entries["in"] {
          rm.entries["args"] = .list([inv])
        }
        if let ctxData = entry.entries["ctx"] { rm.entries["ctx"] = ctxData }
        matchDeep(i, .map(matchSpec), .map(rm), "")
        matched = true
      }

      let expectedOut = entry.entries["out"]
      if expectedOut == nil && matched { continue }
      if let expectedOut = expectedOut {
        XCTAssertTrue(deepEqual(result, expectedOut),
          "entry \(i)\(mark): output mismatch:\n  got:  \(canon(result))\n  want: \(canon(expectedOut))")
      }
    }
  }

  // nativeCtx converts a loose Value ctx map into the native [String:Any?]
  // shape Context expects: opname -> String, map fields -> VMap, spec/result/
  // response omitted (materialised as typed objects by the caller).
  static func nativeCtx(_ ctxmap: VMap) -> [String: Any?] {
    var nctx: [String: Any?] = [:]
    for (k, v) in ctxmap.entries {
      if k == "spec" || k == "result" || k == "response" { continue }
      if k == "opname" {
        nctx["opname"] = v.asString ?? ""
      } else if let m = v.asMap {
        nctx[k] = m
      } else {
        nctx[k] = v
      }
    }
    return nctx
  }

  // makeCtxFromMap builds a Context from a JSON test entry's ctx/args map,
  // materialising typed spec/result/response from their JSON shapes.
  static func makeCtxFromMap(_ ctxmapIn: VMap?, _ client: UnivecSDK?, _ utility: Utility?)
    -> Context
  {
    let ctxmap = ctxmapIn ?? VMap()

    let ctx = Context(nativeCtx(ctxmap), nil)

    if let client = client {
      ctx.client = client
      ctx.utility = utility
    }
    if ctx.options == nil, let client = client {
      ctx.options = client.optionsMap()
    }

    if let specMap = ctxmap.entries["spec"]?.asMap {
      ctx.spec = Spec(specMap)
    }

    if let resMap = ctxmap.entries["result"]?.asMap {
      ctx.result = Result(resMap)
      if let errMap = resMap.entries["err"]?.asMap, let msg = errMap.entries["message"]?.asString {
        ctx.result!.err = UnivecError("", msg, nil)
      }
    }

    if let respMap = ctxmap.entries["response"]?.asMap {
      ctx.response = Response(respMap)
      if let body = respMap.entries["body"], !isNil(body) {
        let captured = body
        ctx.response!.jsonFunc = { () -> Value in captured }
      }
      if let headers = respMap.entries["headers"]?.asMap {
        let lower = VMap()
        for (k, v) in headers.entries { lower.entries[k.lowercased()] = v }
        ctx.response!.headers = .map(lower)
      }
    }

    return ctx
  }

  static func fixCtx(_ ctx: Context, _ client: UnivecSDK) {
    if ctx.client != nil && ctx.options == nil {
      ctx.options = ctx.client!.optionsMap()
    }
  }

  static func errFromMap(_ m: VMap?) -> Error? {
    guard let m = m, let msg = m.entries["message"]?.asString, msg != "" else { return nil }
    let code = m.entries["code"]?.asString ?? ""
    return UnivecError(code, msg, nil)
  }
}
