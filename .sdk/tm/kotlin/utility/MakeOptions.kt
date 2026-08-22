package KOTLINPACKAGE.utility

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.utility.struct.Struct

@Suppress("UNCHECKED_CAST")
fun makeOptions(ctx: Context): MutableMap<String, Any?> {
  var options = ctx.options
  if (options == null) {
    options = linkedMapOf()
  }

  // Merge custom utility overrides onto the utility object.
  // Read from original options before clone for parity with the donors.
  val customUtils = Helpers.toMapAny(options["utility"])
  if (customUtils != null && ctx.utility != null) {
    ctx.utility!!.custom.putAll(customUtils)
  }

  var opts = Struct.clone(options) as MutableMap<String, Any?>

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

  var config = ctx.config
  if (config == null) {
    config = linkedMapOf()
  }
  var cfgopts = Helpers.toMapAny(config["options"])
  if (cfgopts == null) {
    cfgopts = linkedMapOf()
  }

  val optspec = Json.parse(
    "{" +
      "\"apikey\": \"\"," +
      "\"base\": \"http://localhost:8000\"," +
      "\"prefix\": \"\"," +
      "\"suffix\": \"\"," +
      "\"auth\": { \"prefix\": \"\" }," +
      "\"headers\": { \"`\$CHILD`\": \"`\$STRING`\" }," +
      "\"allow\": {" +
      "  \"method\": \"GET,PUT,POST,PATCH,DELETE,OPTIONS\"," +
      "  \"op\": \"create,update,load,list,remove,command,direct,graphql\"" +
      "}," +
      "\"entity\": { \"`\$CHILD`\": {" +
      "  \"`\$OPEN`\": true, \"active\": false, \"alias\": {} } }," +
      "\"feature\": { \"`\$CHILD`\": {" +
      "  \"`\$OPEN`\": true, \"active\": false } }," +
      "\"utility\": {}," +
      "\"system\": {}," +
      "\"test\": { \"active\": false, \"entity\": { \"`\$OPEN`\": true } }," +
      "\"clean\": { \"keys\": \"key,token,id\" }" +
      "}",
  ) as MutableMap<String, Any?>

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
  val validated = Struct.validate(merged, optspec, vopts)
  opts = validated as MutableMap<String, Any?>

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

  // Derived clean config.
  var cleanKeys = "key,token,id"
  val ck = Struct.getpath(opts, listOf("clean", "keys"))
  if (ck is String) {
    cleanKeys = ck
  }

  val filtered = mutableListOf<String>()
  for (pRaw in cleanKeys.split(",")) {
    val p = pRaw.trim()
    if ("" != p) {
      filtered.add(Struct.escre(p))
    }
  }
  val keyre = filtered.joinToString("|")

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
  val derivedClean = linkedMapOf<String, Any?>()
  if ("" != keyre) {
    derivedClean["keyre"] = keyre
  }
  derived["clean"] = derivedClean
  derived["featureorder"] = featureorder
  opts["__derived__"] = derived

  return opts
}
