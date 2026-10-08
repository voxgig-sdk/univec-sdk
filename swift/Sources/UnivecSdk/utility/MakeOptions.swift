// Univec SDK utility: makeOptions - merge, validate and derive the
// client options.

import Foundation


func makeOptionsUtil(_ ctx: Context) -> VMap {
  let options = ctx.options ?? VMap()

  // Merge utility overrides from options onto the utility object. Read from
  // the original options before clone for safety.
  //
  // `fetcher` REPLACES the member; every other key is attached as a custom
  // extra. Shelving the fetcher too made `utility: ["fetcher": ...]`, the
  // documented transport seam, a silent no-op here while ts honoured it - and
  // it is the seam the shared feature corpus scripts.
  //
  // PARTIAL, DELIBERATELY. The other members are replaceable in principle -
  // Value.native carries any Swift value - but each has a distinct closure
  // type, so honouring them means one `as?` arm per member with the signature
  // written exactly. `fetcher` is the documented seam and the one the corpus
  // needs; the rest stay in `custom` until a swift toolchain can compile the
  // arms rather than have them written blind. See AGENTS.md.
  if let customUtils = gp(options, "utility").asMap {
    if let utility = ctx.utility {
      for (k, v) in customUtils.entries {
        let native = v.asNative ?? v
        if "fetcher" == k, let fn = native as? FetcherFunc {
          utility.fetcher = fn
        }
        else {
          utility.custom[k] = native
        }
      }
    }
  }

  // `auth: .null` is the documented way to disable auth outright, and
  // prepareAuth honours it before it ever reads the apikey. It cannot survive
  // validate: depending on the struct port a stored null is either REPLACED
  // by the optspec default - transmitting the credential the caller withheld
  // - or REJECTED outright. Withhold the key for validate, then put the null
  // back. Same fix as ts/js/go makeOptions.
  //
  // `isNull` rather than `isNil`: the latter is also true for Noval, so it
  // cannot tell an ABSENT auth from a suppressed one, and only the latter is
  // a suppression.
  let authSuppressed = options.entries["auth"]?.isNull ?? false

  let opts = clone(.map(options)).asMap ?? VMap()

  if authSuppressed {
    opts.entries.removeValue(forKey: "auth")
  }

  let config = ctx.config ?? VMap()
  let cfgopts = gp(config, "options").asMap ?? VMap()

  // The secret registry exists BEFORE validation, fed from the raw input, so
  // the constructor's own rejection of a mistyped credential is clean too.
  // (Here validate never throws - the struct port collects its errors - so
  // there is no rejection to clean; the registry is early for the same
  // reason regardless.)
  var cleanlayers: [Value] = [.map(VMap()), clone(gp(SdkSchema.optspec, "clean"))]
  // Maps only: merge lets any other value replace the defaults outright.
  for block in [gp(cfgopts, "clean"), opts.entries["clean"] ?? .noval] {
    if let m = block.asMap {
      cleanlayers.append(clone(.map(m)))
    }
  }
  let cleancfg = makeCleanConfig(merge(.list(cleanlayers)))
  let cleanctx = Context(
    ["options": vm(("__derived__", .map(vm(("clean", .nat(cleancfg))))))], nil)
  cleanAddOptions(cleanctx, cleanOmit(opts, ["clean"]))
  let cleanvalues = cleanSplitValues(gpath(cfgopts, "clean", "values"))
    + cleanSplitValues(gpath(opts, "clean", "values"))
  for raw in cleanvalues {
    cleanAddUtil(cleanctx, .string(raw))
  }

  // Feature add-order. options.feature may be given as an ordered LIST of
  // { name, active, ...opts } entries (the list position IS the order in which
  // features are added), or as a { name: {opts} } map. Normalize a list to a
  // map (so merge/validate/init are unchanged) and remember the explicit
  // order; a map defaults to test-first so the `test` mock transport is
  // installed as the base of the transport wrapper chain.
  var featureorder: [Value] = []
  if let flist = opts.entries["feature"]?.asList {
    let fmap = VMap()
    for entry in flist.items {
      if let em = entry.asMap, let fname = em.entries["name"]?.asString, fname != "" {
        let fopts = VMap()
        for (k, v) in em.entries where k != "name" { fopts.entries[k] = v }
        fmap.entries[fname] = .map(fopts)
        featureorder.append(.string(fname))
      }
    }
    opts.entries["feature"] = .map(fmap)
  }

  // THE OPTION SPEC IS GENERATED, NOT WRITTEN HERE.
  //
  // Built from the model: `main.kit.optspec` for the standard options, plus
  // one entry per feature this target carries, from that feature's own
  // `config.options` / `config.optspec`. Editing this file to add an option
  // would put it back where it was - one of twenty hand-maintained copies of
  // a schema nothing cross-checked - so add it to the model instead and every
  // ported target validates it.
  //
  // Already parsed, and shared: makeOptions validates AGAINST the spec and
  // writes into the options, never into the spec.
  let optspec = SdkSchema.optspec

  // Preserve system.fetch across merge/validate (closures survive Clone, but
  // validation reshapes the system block).
  let sysFetch = gpath(opts, "system", "fetch")

  // CLONE the config side: `config` is a process-wide singleton
  // (SdkConfig.sharedConfig) and merge uses its nested maps as merge TARGETS,
  // so without this one client's options (headers, server, ...) are written
  // into the shared config and inherited by every client built afterwards.
  let merged = merge(.list([.map(VMap()), clone(.map(cfgopts)), .map(opts)]))
  let validated = validate(merged, optspec)
  let result = validated.asMap ?? VMap()

  // Restore the suppression the optspec default would otherwise erase.
  if authSuppressed {
    result.entries["auth"] = .null
  }

  // Restore system.fetch.
  if !isNil(sysFetch) {
    if let sm = gp(result, "system").asMap {
      sm.entries["fetch"] = sysFetch
    } else {
      let sm = VMap()
      sm.entries["fetch"] = sysFetch
      result.entries["system"] = .map(sm)
    }
  }

  if let base = result.entries["base"]?.asString, base.contains("{") {
    do {
      let resolved = try resolveServerBase(base, result, config, ctx)
      result.entries["base"] = .string(resolved)
    } catch {
      // The initializer cannot throw, so a construction error traps, as zig's panics.
      fatalError(errMessage(error))
    }
  }

  // Resolve the feature add-order: an explicit list order (above) wins;
  // otherwise order the map test-first, then the remaining names sorted, so
  // the outcome is deterministic and `test` is always the base transport.
  if featureorder.isEmpty {
    let fmap = gp(result, "feature").asMap ?? VMap()
    let names = fmap.entries.keys.sorted()
    if names.contains("test") {
      featureorder.append(.string("test"))
      for n in names where n != "test" { featureorder.append(.string(n)) }
    } else {
      for n in names { featureorder.append(.string(n)) }
    }

    // Station special case, mirroring test's: its transport wrap must
    // sit immediately outside the base transport (inside retry/cache/
    // netsim), so map-form activation hoists it to just after test -
    // or first, when no test entry exists. Without this the sorted
    // default would init station last and wrap OUTSIDE the recording
    // features, turning its wire-truth events into fiction.
    if let si = featureorder.firstIndex(where: { $0.asString == "station" }) {
      featureorder.remove(at: si)
      let ti = featureorder.firstIndex(where: { $0.asString == "test" })
      featureorder.insert(.string("station"), at: (ti ?? -1) + 1)
    }
  }

  let derived = VMap()
  derived.entries["clean"] = .nat(cleancfg)
  derived.entries["featureorder"] = .list(VList(featureorder))
  result.entries["__derived__"] = .map(derived)

  // Again over the merged result: the config's own defaults can carry one.
  cleanAddOptions(Context(["options": result], nil), cleanOmit(result, ["clean", "__derived__"]))

  return result
}

// A templated base URL takes each {name} from options.server. An empty value
// cannot make a working URL, so it is an error, except in test mode, where it
// becomes test-<name>.
func resolveServerBase(_ base: String, _ opts: VMap, _ config: VMap, _ ctx: Context?) throws -> String {
  let testmode = gpath(opts, "test", "active") == .bool(true)
    || gpath(opts, "feature", "test", "active") == .bool(true)
  let server = gp(opts, "server").asMap ?? VMap()
  var sdkname = gpath(config, "main", "name").asString ?? ""
  if sdkname.isEmpty { sdkname = "SDK" }

  let chars = Array(base)
  var out = ""
  var i = 0
  while i < chars.count {
    var j = i + 1
    if "{" == chars[i] {
      while j < chars.count, "_" == chars[j] || (chars[j].isASCII && (chars[j].isLetter || chars[j].isNumber)) {
        j += 1
      }
    }
    // A placeholder only when it closes and the name is [A-Za-z0-9_]+.
    if "{" != chars[i] || j == i + 1 || j >= chars.count || "}" != chars[j] {
      out.append(chars[i])
      i += 1
      continue
    }
    let name = String(chars[(i + 1)..<j])
    let value = gp(server, name).asString ?? ""
    if !value.isEmpty {
      out += value
    } else if testmode {
      out += "test-" + name
    } else {
      let hint = "options.entries[\"server\"] = .map(server) with server.entries[\"\(name)\"]"
        + " = .string(\"...\")"
      throw UnivecError("server_var_required",
        "\(sdkname): the server variable '\(name)' is required: the API base URL is '\(base)'"
          + " - pass \(hint) in the SDK options", ctx)
    }
    i = j + 1
  }
  return out
}

// A feature's name is not a field name: only the sensitive names inside its
// settings count, so `secrets` does not make every setting a secret. Entity
// blocks hold entity settings and seeded records, never a credential, and
// rbac's rules are keyed by entity and operation names.
private func cleanAddOptions(_ ctx: Context, _ opts: VMap) {
  let top = cleanOmit(opts, ["feature", "entity"])
  if let test = top.entries["test"] {
    top.entries["test"] = cleanPlain(test, nil)
  }
  cleanAddSensitiveUtil(ctx, .map(top))
  let feature = opts.entries["feature"] ?? .noval
  var settings: [(String?, Value)] = []
  if let fmap = feature.asMap {
    for (name, fopts) in fmap.entries {
      settings.append((name, fopts))
    }
  } else if let flist = feature.asList {
    for fopts in flist.items {
      settings.append((fopts.asMap?.entries["name"]?.asString, fopts))
    }
  } else {
    settings.append((nil, feature))
  }
  for (name, fopts) in settings {
    cleanAddSensitiveUtil(ctx, cleanPlain(fopts, name))
  }
}

private func cleanPlain(_ block: Value, _ name: String?) -> Value {
  guard let m = block.asMap else { return block }
  return .map(cleanOmit(m, "rbac" == name ? ["entity", "rules"] : ["entity"]))
}

private func cleanOmit(_ src: VMap, _ names: [String]) -> VMap {
  let out = VMap()
  for (k, v) in src.entries where !names.contains(k) {
    out.entries[k] = v
  }
  return out
}
