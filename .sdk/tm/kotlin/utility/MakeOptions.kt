package KOTLINPACKAGE.utility

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.Schema
import KOTLINPACKAGE.core.SdkError
import KOTLINPACKAGE.core.Utility
import KOTLINPACKAGE.utility.struct.Struct

// A {name} placeholder in a templated server URL (an OpenAPI server variable).
private val SERVER_VAR = Regex("\\{([A-Za-z0-9_]+)\\}")

@Suppress("UNCHECKED_CAST")
fun makeOptions(ctx: Context): MutableMap<String, Any?> {
  var options = ctx.options
  if (options == null) {
    options = linkedMapOf()
  }

  // Merge utility overrides from options onto the utility object.
  // Read from original options before clone for parity with the donors.
  //
  // A key naming a real utility member REPLACES it; anything else is attached
  // as a custom extra. Shelving everything in `custom` - a map nothing reads -
  // made `utility = mapOf("fetcher" to ...)`, the documented transport seam, a
  // silent no-op here while ts honoured it.
  val customUtils = Helpers.toMapAny(options["utility"])
  if (customUtils != null && ctx.utility != null) {
    for ((key, value) in customUtils) {
      if (!overrideUtil(ctx.utility!!, key, value)) {
        ctx.utility!!.custom[key] = value
      }
    }
  }

  // `auth: null` is the documented way to disable auth outright, and
  // PrepareAuth honours it before it ever reads the apikey. It cannot survive
  // validate: depending on the struct port a stored null is either REPLACED
  // by the optspec default - transmitting the credential the caller withheld
  // - or REJECTED outright. Withhold the key for validate, then put the null
  // back. Same fix as ts/js/go makeOptions.
  //
  // Suppliedness cannot be recovered after validate, hence here, and it must
  // tell an ABSENT auth from a present null: containsKey rather than a null
  // check on the value, which cannot distinguish them.
  val authSuppressed = options.containsKey("auth") && null == options["auth"]

  var config = ctx.config
  if (config == null) {
    config = linkedMapOf()
  }
  var cfgopts = Helpers.toMapAny(config["options"])
  if (cfgopts == null) {
    cfgopts = linkedMapOf()
  }

  // The secret registry exists BEFORE validation, fed from the raw input, so
  // the constructor's own rejection of a mistyped credential is clean too.
  // Both clean blocks are cloned for the reason the options merge below is,
  // and an absent one is left out: merge lets a null replace everything.
  val cleanblocks = listOf(Helpers.toMapAny(cfgopts["clean"]), Helpers.toMapAny(options["clean"]))
  val cleanmerge = mutableListOf<Any?>(linkedMapOf<String, Any?>(), Struct.clone(Schema.optspec["clean"]))
  for (block in cleanblocks.filterNotNull()) {
    cleanmerge.add(Struct.clone(block))
  }
  val cleancfg = makeCleanConfig(Struct.merge(cleanmerge))
  registerSensitive(cleancfg, options - "clean")
  for (block in cleanblocks) {
    for (raw in splitvalues(block?.get("values"))) {
      registerValue(cleancfg, raw)
    }
  }

  var opts = Struct.clone(options) as MutableMap<String, Any?>

  if (authSuppressed) {
    opts.remove("auth")
  }

  // Feature add-order. options.feature may be given as an ordered LIST of
  // { name, active, ...opts } entries (the list position IS the order in which
  // features are added), or as a { name: {opts} } map. Normalize a list to a
  // map (so merge/validate/init are unchanged) and remember the explicit
  // order; a map defaults to test-first so the `test` mock transport is
  // installed as the base of the transport wrapper chain.
  val featureorder = mutableListOf<Any?>()
  val frawInit = opts["feature"]
  if (frawInit is List<*>) {
    val fmap = linkedMapOf<String, Any?>()
    for (entry in frawInit) {
      val em = Helpers.toMapAny(entry)
      val fname = em?.get("name") as? String
      if (em != null && fname != null && "" != fname) {
        val fopts = linkedMapOf<String, Any?>()
        fopts.putAll(em)
        fopts.remove("name")
        fmap[fname] = fopts
        featureorder.add(fname)
      }
    }
    opts["feature"] = fmap
  }

  // THE OPTION SPEC IS GENERATED, NOT WRITTEN HERE.
  //
  // Built from the model: `main.kit.optspec` for the standard options, plus
  // one entry per feature this target carries, from that feature's own
  // `config.options` / `config.optspec`. Editing this file to add an option
  // would put it back where it was — one of twenty hand-maintained copies of
  // a schema nothing cross-checked — so add it to the model instead and every
  // ported target validates it.
  //
  // Already parsed, and shared: makeOptions validates AGAINST the spec and
  // writes into the options, never into the spec.
  val optspec = Schema.optspec

  // Preserve system.fetch before merge/validate.
  var sysFetch = Struct.getpath(opts, listOf("system", "fetch"))
  if (sysFetch === Struct.UNDEF) {
    sysFetch = null
  }

  val mergeList = mutableListOf<Any?>()
  mergeList.add(linkedMapOf<String, Any?>())
  // CLONE the config side: `config` is a process-wide singleton
  // (Config.sharedConfig) and merge uses its nested maps as merge TARGETS, so
  // without this one client's options (headers, server, ...) are written into
  // the shared config and inherited by every client constructed afterwards.
  mergeList.add(Struct.clone(cfgopts))
  mergeList.add(opts)
  val merged = Struct.merge(mergeList)

  val vopts = linkedMapOf<String, Any?>()
  vopts["errs"] = mutableListOf<Any?>()
  val validated = try {
    Struct.validate(merged, optspec, vopts)
  } catch (err: RuntimeException) {
    // A rejection quotes the value it rejected.
    throw SdkError("options_invalid",
      cleanWith(cleancfg, err.message ?: err.toString()) as String, ctx)
  }
  opts = validated as MutableMap<String, Any?>

  // Restore the suppression the optspec default would otherwise erase.
  if (authSuppressed) {
    opts["auth"] = null
  }

  // Restore system.fetch.
  if (sysFetch != null) {
    val sys = Helpers.toMapAny(opts["system"])
    if (sys != null) {
      sys["fetch"] = sysFetch
    } else {
      val sm = linkedMapOf<String, Any?>()
      sm["fetch"] = sysFetch
      opts["system"] = sm
    }
  }

  // A templated base URL takes each {name} from options.server. An empty value
  // cannot make a working URL, so it fails construction, except in test mode,
  // where it becomes test-<name>.
  val base = opts["base"]
  if (base is String && base.contains('{')) {
    val testmode = true == Struct.getpath(opts, listOf("test", "active")) ||
      true == Struct.getpath(opts, listOf("feature", "test", "active"))
    val server = Helpers.toMapAny(opts["server"])
    val mainName = Struct.getpath(config, listOf("main", "name"))
    val sdkname = if (mainName is String && "" != mainName) mainName else "SDK"
    opts["base"] = SERVER_VAR.replace(base) { m ->
      val name = m.groupValues[1]
      val value = server?.get(name) as? String ?: ""
      when {
        "" != value -> value
        testmode -> "test-$name"
        else -> throw SdkError("server_var_required",
          "$sdkname: the server variable '$name' is required: the API base URL is " +
            "'$base' - pass \"server\" to mapOf(\"$name\" to \"...\") in the SDK options", ctx)
      }
    }
  }

  // Resolve the feature add-order: an explicit list order (above) wins;
  // otherwise order the map test-first, then the remaining names sorted, so
  // the outcome is deterministic and `test` is always the base transport.
  if (featureorder.isEmpty()) {
    val fmap = Helpers.toMapAny(opts["feature"])
    val names = (fmap?.keys?.toMutableList() ?: mutableListOf()).also { it.sort() }
    if (names.contains("test")) {
      featureorder.add("test")
      for (n in names) {
        if ("test" != n) {
          featureorder.add(n)
        }
      }
    } else {
      featureorder.addAll(names)
    }
    // Station special case, mirroring test's: its transport wrap must
    // sit immediately outside the base transport (inside retry/cache/
    // netsim), so map-form activation hoists it to just after test -
    // or first, when no test entry exists. Without this the sorted
    // default would init station last and wrap OUTSIDE the recording
    // features, turning its wire-truth events into fiction.
    val si = featureorder.indexOf("station")
    if (0 <= si) {
      featureorder.removeAt(si)
      featureorder.add(featureorder.indexOf("test") + 1, "station")
    }
  }

  val derived = linkedMapOf<String, Any?>()
  derived["clean"] = cleancfg
  derived["featureorder"] = featureorder
  opts["__derived__"] = derived

  // Again over the merged result: the config's own defaults can carry one.
  registerSensitive(cleancfg, opts - "clean" - "__derived__")

  return opts
}


/**
 * Replaces one utility member from `options.utility`, matching the ts
 * reference: a key naming a real member REPLACES it, and any other key is
 * attached as a custom extra. Returns false when the key names no member or
 * the value is not that member's type, so the caller keeps it in `custom`.
 *
 * REFLECTION, NOT A KEYED SWITCH. The go and java ports list every member by
 * hand and carry a "keep this in step with registerAll" warning, because a
 * utility added to one list and not the other is overridable there and not
 * here. The field set is readable off the class, so the list cannot drift.
 *
 * Kotlin function types erase to FunctionN, so `isInstance` checks arity and
 * not the full signature - the same limit java's port documents. A wrongly
 * shaped value of the right arity is accepted, exactly as the dynamic donors
 * accept whatever they are given.
 *
 * Only a PUBLIC name may replace a member: public utility names are camelCase
 * and carry no underscore, so an underscore means the caller named something
 * of their own rather than a member.
 */
internal fun overrideUtil(utility: Utility, key: String, value: Any?): Boolean {
  if (key.isEmpty() || key.contains('_') || "custom" == key) {
    return false
  }
  if (null == value) {
    return false
  }

  val field = try {
    Utility::class.java.getDeclaredField(key)
  } catch (e: NoSuchFieldException) {
    return false
  }

  if (!field.type.isInstance(value)) {
    return false
  }

  field.isAccessible = true
  field.set(utility, value)
  return true
}
