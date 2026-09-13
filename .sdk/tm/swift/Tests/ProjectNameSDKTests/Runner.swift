// Univec SDK test SUPPORT - shared infrastructure for the generated
// test suites. SUPPORT ONLY: the corpus ENGINE that used to live here
// (runSet / matchDeep, a second hand-written implementation of omni's
// runner) is retired in favour of the vendored @voxgig/omni port, driven
// through OmniResolver. The file KEEPS ITS NAME and the SdkRunner enum
// keeps its members, so every emitted call site - FeatureTest's deepEqual /
// matchString / errCode, the primary suite's makeCtxFromMap / fixCtx /
// errFromMap - needs no churn.
//
// What survives here is everything that is ABOUT THE SDK rather than about
// running a corpus: where the shared spec lives, how a loose ctx map
// becomes the typed Context a generated utility takes, and the value
// comparison the behavioural (non-corpus) suites use.

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

  // Canonical sorted-key JSON with .noval/.null unification, for the
  // BEHAVIOURAL suites' own assertions (FeatureTest). The corpus lanes
  // compare through omni's deepequal/matchval instead - .noval and .null
  // are DISTINCT there, which is the whole point of the `null` flag.
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
