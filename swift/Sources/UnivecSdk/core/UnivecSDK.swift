// Univec SDK client.
//
// SDK TYPES ARE MODULE-QUALIFIED IN THIS FILE (`UnivecSdk.VMap`, not
// `VMap`), and only in this file. MainEntity_swift emits one accessor PER
// ENTITY into this class body, named after the entity - `Utility()`,
// `Spec()`, `Value()` for an API with entities of those names - and inside
// a class body a METHOD of that name shadows the TYPE for every unqualified
// use: `utility = Utility()` then reads as a call to the accessor, and
// `-> Utility` as a return type that does not exist. The entity TYPE is
// already renamed on such a collision (swiftSafeTypeName), but the accessor
// keeps the entity's own name, which is the public API. Qualifying by
// module - the generated module is <Name>Sdk, so `UnivecSdk.` lands as
// `<Name>Sdk.` - is the one spelling a method cannot shadow. The shared
// fixture's `utility` entity is what found this; every other swift file is
// outside this class and unaffected.

import Foundation

public final class UnivecSDK {
  public var mode = "live"
  private var options: UnivecSdk.VMap = UnivecSdk.VMap()
  private let utility: UnivecSdk.Utility
  public var features: [BaseFeature] = []
  private var rootctx: UnivecSdk.Context!

  public init(_ optionsIn: UnivecSdk.VMap? = nil) {
    utility = UnivecSdk.Utility()

    // The process-wide config (sdkgen rung L2): read-only on the request path,
    // so every client shares one rather than rebuilding it.
    let config = SdkConfig.sharedConfig()

    var ctxmap: [String: Any?] = [
      "client": self,
      "utility": utility,
      "config": config,
      "shared": UnivecSdk.VMap(),
    ]
    if let o = optionsIn { ctxmap["options"] = o }

    rootctx = utility.makeContext(ctxmap, nil)

    options = utility.makeOptions(rootctx)

    if gpath(options, "feature", "test", "active") == .bool(true) {
      mode = "test"
    }

    rootctx.options = options

    // Add features in the resolved order (makeOptions puts an explicit list
    // order first, else defaults to test-first). Ordering matters: the `test`
    // feature installs the base mock transport and the transport features
    // (retry/cache/netsim/proxy/ratelimit) wrap whatever is current, so `test`
    // must be added before them to sit at the base of the chain.
    let featureOpts = gp(options, "feature").asMap ?? UnivecSdk.VMap()
    if let featureOrder = gpath(options, "__derived__", "featureorder").asList {
      for fnameVal in featureOrder.items {
        let fname = fnameVal.asString ?? ""
        if fname != "", let fopts = gp(featureOpts, fname).asMap,
          fopts.entries["active"]?.asBool == true {
          utility.featureAdd(rootctx, SdkConfig.makeFeature(fname))
        }
      }
    }

    // Add extension features.
    if let extList = gp(options, "extend").asList {
      for f in extList.items {
        if let feat = f.asNative as? BaseFeature {
          utility.featureAdd(rootctx, feat)
        }
      }
    }

    // Initialize features.
    for f in features {
      utility.featureInit(rootctx, f)
    }

    utility.featureHook(rootctx, "PostConstruct")
  }

  public func optionsMap() -> UnivecSdk.VMap {
    return clone(.map(options)).asMap ?? UnivecSdk.VMap()
  }

  public func getUtility() -> UnivecSdk.Utility {
    return UnivecSdk.Utility.copy(utility)
  }

  public func getRootCtx() -> UnivecSdk.Context {
    return rootctx
  }

  public func prepare(_ fetchargsIn: UnivecSdk.VMap?) throws -> UnivecSdk.VMap {
    let utility = self.utility

    let fetchargs = fetchargsIn ?? UnivecSdk.VMap()

    let ctrl = gp(fetchargs, "ctrl").asMap ?? UnivecSdk.VMap()

    let ctx = utility.makeContext(["opname": "prepare", "ctrl": ctrl], rootctx)

    let options = self.options

    let path = gp(fetchargs, "path").asString ?? ""
    var method = gp(fetchargs, "method").asString ?? ""
    if method == "" { method = "GET" }

    let pathParams = gp(fetchargs, "params").asMap ?? UnivecSdk.VMap()
    let query = gp(fetchargs, "query").asMap ?? UnivecSdk.VMap()

    let headers = utility.prepareHeaders(ctx)

    let basev = gp(options, "base").asString ?? ""
    let prefix = gp(options, "prefix").asString ?? ""
    let suffix = gp(options, "suffix").asString ?? ""

    let specmap = UnivecSdk.VMap()
    specmap.entries["base"] = .string(basev)
    specmap.entries["prefix"] = .string(prefix)
    specmap.entries["suffix"] = .string(suffix)
    specmap.entries["path"] = .string(path)
    specmap.entries["method"] = .string(method)
    specmap.entries["params"] = .map(pathParams)
    specmap.entries["query"] = .map(query)
    specmap.entries["headers"] = .map(headers)
    specmap.entries["body"] = gp(fetchargs, "body")
    specmap.entries["step"] = .string("start")
    ctx.spec = UnivecSdk.Spec(specmap)

    // Merge user-provided headers.
    if let uhm = gp(fetchargs, "headers").asMap {
      for (k, v) in uhm.entries {
        ctx.spec!.headers.entries[k] = v
      }
    }

    _ = try utility.prepareAuth(ctx)

    return try utility.makeFetchDef(ctx)
  }

  // Raw endpoint access is operator-controllable, like every entity op.
  // Blocking it means denying BOTH the 'direct' and 'graphql' tokens, since
  // either one reaches the same endpoint.
  public func direct(_ fetchargsIn: UnivecSdk.VMap?) -> UnivecSdk.VMap {
    if !opAllowed("direct") {
      return opDenied("direct")
    }

    return rawRequest(fetchargsIn)
  }

  // Is this raw-access op permitted by the SDK's allow.op option?
  private func opAllowed(_ op: String) -> Bool {
    guard let allow = gpath(options, "allow", "op").asString else { return false }
    return allow.contains(op)
  }

  private func opDenied(_ op: String) -> UnivecSdk.VMap {
    let allow = gpath(options, "allow", "op").asString ?? ""
    let r = UnivecSdk.VMap()
    r.entries["ok"] = .bool(false)
    r.entries["err"] = .nat(UnivecError(
      op + "_allow",
      "UnivecSDK: \(op): operation not allowed by SDK option "
        + "allow.op value: \"\(allow)\"", nil))
    return r
  }

  // Ungated request path shared by direct and graphql, each of which checks
  // its own allow.op token first. Private, rather than a flag on fetchargs:
  // a caller-supplied marker would let anyone opt straight back out of the
  // gate by passing it.
  private func rawRequest(_ fetchargsIn: UnivecSdk.VMap?) -> UnivecSdk.VMap {
    let utility = self.utility

    let fetchdef: UnivecSdk.VMap
    do {
      fetchdef = try prepare(fetchargsIn)
    } catch {
      let r = UnivecSdk.VMap()
      r.entries["ok"] = .bool(false)
      r.entries["err"] = .nat(error)
      return r
    }

    let fetchargs = fetchargsIn ?? UnivecSdk.VMap()
    let ctrl = gp(fetchargs, "ctrl").asMap ?? UnivecSdk.VMap()

    let ctx = utility.makeContext(["opname": "direct", "ctrl": ctrl], rootctx)

    let url = gp(fetchdef, "url").asString ?? ""

    let fetched: UnivecSdk.Value
    do {
      fetched = try utility.fetcher(ctx, url, fetchdef)
    } catch {
      let r = UnivecSdk.VMap()
      r.entries["ok"] = .bool(false)
      r.entries["err"] = .nat(error)
      return r
    }

    if isNil(fetched) {
      let r = UnivecSdk.VMap()
      r.entries["ok"] = .bool(false)
      r.entries["err"] = .nat(ctx.makeError("direct_no_response", "response: undefined"))
      return r
    }

    if let fm = fetched.asMap {
      let status = toInt(gp(fm, "status"))
      let headers = gp(fm, "headers")

      // No-body responses (204, 304) and explicit zero content-length must
      // skip JSON parsing.
      var contentLength = ""
      if let hm = headers.asMap, let cl = hm.entries["content-length"], !isNil(cl) {
        contentLength = stringify(cl)
      }
      let noBody = status == 204 || status == 304 || contentLength == "0"

      var jsonData: UnivecSdk.Value = .noval
      if !noBody, let jf = gp(fm, "json").asNative as? UnivecSdk.NativeCall0 {
        jsonData = jf()
      }

      let r = UnivecSdk.VMap()
      r.entries["ok"] = .bool(status >= 200 && status < 300)
      r.entries["status"] = .int(Int64(status))
      r.entries["headers"] = headers
      r.entries["data"] = jsonData
      return r
    }

    let r = UnivecSdk.VMap()
    r.entries["ok"] = .bool(false)
    r.entries["err"] = .nat(ctx.makeError("direct_invalid", "invalid response type"))
    return r
  }

  // Raw GraphQL access: the pressure valve that makes the generated surface's
  // deliberate omissions (per-call selection sets, typed filter builders,
  // batching, subscriptions) livable — the whole schema stays reachable.
  //
  // Thin wrapper over the same prepare/fetch path direct uses, with the one
  // thing raw direct cannot do for GraphQL: a GraphQL failure rides HTTP 200
  // as a top-level `errors` array, so status alone would report a failed
  // query as ok.
  //
  // NOTE: like direct, this bypasses the feature pipeline — no retry,
  // ratelimit or paging features apply.
  public func graphql(
    _ query: String, _ variables: UnivecSdk.VMap? = nil, _ ctrl: UnivecSdk.VMap? = nil
  ) -> UnivecSdk.VMap {
    if !opAllowed("graphql") {
      return opDenied("graphql")
    }

    let headers = UnivecSdk.VMap()
    headers.entries["content-type"] = .string("application/json")

    let body = UnivecSdk.VMap()
    body.entries["query"] = .string(query)
    body.entries["variables"] = .map(variables ?? UnivecSdk.VMap())

    let fetchargs = UnivecSdk.VMap()
    fetchargs.entries["method"] = .string("POST")
    fetchargs.entries["headers"] = .map(headers)
    fetchargs.entries["body"] = .map(body)
    fetchargs.entries["ctrl"] = .map(ctrl ?? UnivecSdk.VMap())

    let res = rawRequest(fetchargs)

    // Errors are read BEFORE any status check: a GraphQL parse or validation
    // failure comes back as HTTP 400 carrying the standard { errors: [...] }
    // body, and the raw path represents a non-2xx as ok:false with no err —
    // so returning early on status would discard the server's own
    // diagnostics, which are the only useful part of that response.
    guard let errors = gp(gp(.map(res), "data"), "errors").asList,
          !errors.items.isEmpty else {
      return res
    }

    var msg = gp(errors.items[0], "message").asString ?? ""
    if msg.isEmpty { msg = "graphql error" }

    res.entries["ok"] = .bool(false)
    res.entries["err"] = .nat(UnivecError(
      "graphql_error", "UnivecSDK: graphql: " + msg, nil))
    res.entries["graphql"] = .list(errors)

    return res
  }


  // Convert returns a Convert entity bound to this client.
  // Idiomatic usage: try client.Convert().list(nil) or
  // try client.Convert().load(vm(("id", .string("..."))), nil).
  public func Convert(_ entopts: VMap? = nil) -> UnivecEntityBase {
    return ConvertEntity(self, entopts)
  }

  // Embed returns a Embed entity bound to this client.
  // Idiomatic usage: try client.Embed().list(nil) or
  // try client.Embed().load(vm(("id", .string("..."))), nil).
  public func Embed(_ entopts: VMap? = nil) -> UnivecEntityBase {
    return EmbedEntity(self, entopts)
  }

  // EphemeralKey returns a EphemeralKey entity bound to this client.
  // Idiomatic usage: try client.EphemeralKey().list(nil) or
  // try client.EphemeralKey().load(vm(("id", .string("..."))), nil).
  public func EphemeralKey(_ entopts: VMap? = nil) -> UnivecEntityBase {
    return EphemeralKeyEntity(self, entopts)
  }

  // Model returns a Model entity bound to this client.
  // Idiomatic usage: try client.Model().list(nil) or
  // try client.Model().load(vm(("id", .string("..."))), nil).
  public func Model(_ entopts: VMap? = nil) -> UnivecEntityBase {
    return ModelEntity(self, entopts)
  }


  public static func testSDK(_ testoptsIn: UnivecSdk.VMap?, _ sdkoptsIn: UnivecSdk.VMap?) -> UnivecSDK {
    let sdkopts = clone(.map(sdkoptsIn ?? UnivecSdk.VMap())).asMap ?? UnivecSdk.VMap()

    let testopts = clone(.map(testoptsIn ?? UnivecSdk.VMap())).asMap ?? UnivecSdk.VMap()
    testopts.entries["active"] = .bool(true)

    _ = setpath(.map(sdkopts), jtp("feature", "test"), .map(testopts))

    let sdk = UnivecSDK(sdkopts)
    sdk.mode = "test"
    return sdk
  }
}
