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

  let config = ctx.config ?? VMap()
  let cfgopts = gp(config, "options").asMap ?? VMap()

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

  // Derived clean config.
  var cleanKeys = "key,token,id"
  if let cks = gpath(result, "clean", "keys").asString { cleanKeys = cks }

  let filtered = cleanKeys.split(separator: ",", omittingEmptySubsequences: false)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { $0 != "" }
    .map { escre(.string($0)) }
  let keyre = filtered.joined(separator: "|")

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
  derived.entries["clean"] = .map(VMap())
  if keyre != "" {
    let cm = VMap()
    cm.entries["keyre"] = .string(keyre)
    derived.entries["clean"] = .map(cm)
  }
  derived.entries["featureorder"] = .list(VList(featureorder))
  result.entries["__derived__"] = .map(derived)

  return result
}
