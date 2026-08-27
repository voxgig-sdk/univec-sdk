package JAVAPACKAGE.utility;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked"})
final class MakeOptions {

  private MakeOptions() {}

  static Map<String, Object> makeOptions(Context ctx) {
    Map<String, Object> options = ctx.options;
    if (options == null) {
      options = new LinkedHashMap<>();
    }

    // Merge utility overrides from options onto the utility object.
    // Read from original options before clone for parity with the donors.
    //
    // A key naming a real utility member REPLACES it (Register.overrideUtil);
    // anything else is attached as a custom extra. Shelving everything in
    // `custom` - a map nothing reads - made `utility: {"fetcher": ...}`, the
    // documented transport seam, a silent no-op here while ts honoured it.
    Map<String, Object> customUtils = Helpers.toMapAny(options.get("utility"));
    if (customUtils != null && ctx.utility != null) {
      for (Map.Entry<String, Object> cu : customUtils.entrySet()) {
        if (!Register.overrideUtil(ctx.utility, cu.getKey(), cu.getValue())) {
          ctx.utility.custom.put(cu.getKey(), cu.getValue());
        }
      }
    }

    Map<String, Object> opts = (Map<String, Object>) Struct.clone(options);

    // Feature add-order. options.feature may be given as an ordered LIST of
    // { name, active, ...opts } entries (the list position IS the order in
    // which features are added), or as a { name: {opts} } map. Normalize a
    // list to a map (so merge/validate/init are unchanged) and remember the
    // explicit order; a map defaults to test-first so the `test` mock
    // transport is installed as the base of the transport wrapper chain.
    List<Object> featureorder = new ArrayList<>();
    Object frawInit = opts.get("feature");
    if (frawInit instanceof List) {
      Map<String, Object> fmap = new LinkedHashMap<>();
      for (Object entry : (List<Object>) frawInit) {
        Map<String, Object> em = Helpers.toMapAny(entry);
        if (em != null && em.get("name") instanceof String) {
          String fname = (String) em.get("name");
          if (!"".equals(fname)) {
            Map<String, Object> fopts = new LinkedHashMap<>(em);
            fopts.remove("name");
            fmap.put(fname, fopts);
            featureorder.add(fname);
          }
        }
      }
      opts.put("feature", fmap);
    }

    Map<String, Object> config = ctx.config;
    if (config == null) {
      config = new LinkedHashMap<>();
    }
    Map<String, Object> cfgopts = Helpers.toMapAny(config.get("options"));
    if (cfgopts == null) {
      cfgopts = new LinkedHashMap<>();
    }

    Map<String, Object> optspec = (Map<String, Object>) Json.parse(
        "{"
        + "\"apikey\": \"\","
        + "\"base\": \"http://localhost:8000\","
        + "\"prefix\": \"\","
        + "\"suffix\": \"\","
        + "\"auth\": { \"prefix\": \"\" },"
        + "\"headers\": { \"`$CHILD`\": \"`$STRING`\" },"
        + "\"allow\": {"
        + "  \"method\": \"GET,PUT,POST,PATCH,DELETE,OPTIONS\","
        + "  \"op\": \"create,update,load,list,remove,command,direct,graphql\""
        + "},"
        + "\"entity\": { \"`$CHILD`\": {"
        + "  \"`$OPEN`\": true, \"active\": false, \"alias\": {} } },"
        + "\"feature\": { \"`$CHILD`\": {"
        + "  \"`$OPEN`\": true, \"active\": false } },"
        + "\"utility\": {},"
        + "\"system\": {},"
        + "\"test\": { \"active\": false, \"entity\": { \"`$OPEN`\": true } },"
        + "\"clean\": { \"keys\": \"key,token,id\" }"
        + "}");

    // Preserve system.fetch before merge/validate.
    Object sysFetch = Struct.getpath(opts, List.of("system", "fetch"));
    if (sysFetch == Struct.UNDEF) {
      sysFetch = null;
    }

    List<Object> mergeList = new ArrayList<>();
    mergeList.add(new LinkedHashMap<String, Object>());
    // CLONE the config side: `config` is a process-wide singleton
    // (Config.sharedConfig) and merge uses its nested maps as merge TARGETS, so
    // without this one client's options (headers, server, ...) are written into
    // the shared config and inherited by every client constructed afterwards.
    mergeList.add(Struct.clone(cfgopts));
    mergeList.add(opts);
    Object merged = Struct.merge(mergeList);

    Map<String, Object> vopts = new LinkedHashMap<>();
    vopts.put("errs", new ArrayList<>());
    Object validated = Struct.validate(merged, optspec, vopts);
    opts = (Map<String, Object>) validated;

    // Restore system.fetch.
    if (sysFetch != null) {
      Map<String, Object> sys = Helpers.toMapAny(opts.get("system"));
      if (sys != null) {
        sys.put("fetch", sysFetch);
      }
      else {
        Map<String, Object> sm = new LinkedHashMap<>();
        sm.put("fetch", sysFetch);
        opts.put("system", sm);
      }
    }

    // Derived clean config.
    String cleanKeys = "key,token,id";
    Object ck = Struct.getpath(opts, List.of("clean", "keys"));
    if (ck instanceof String) {
      cleanKeys = (String) ck;
    }

    List<String> filtered = new ArrayList<>();
    for (String p : cleanKeys.split(",")) {
      p = p.trim();
      if (!"".equals(p)) {
        filtered.add(Struct.escre(p));
      }
    }
    String keyre = String.join("|", filtered);

    // Resolve the feature add-order: an explicit list order (above) wins;
    // otherwise order the map test-first, then the remaining names sorted, so
    // the outcome is deterministic and `test` is always the base transport.
    if (featureorder.isEmpty()) {
      Map<String, Object> fmap = Helpers.toMapAny(opts.get("feature"));
      List<String> names = new ArrayList<>();
      if (fmap != null) {
        names.addAll(fmap.keySet());
      }
      names.sort(null);
      if (names.contains("test")) {
        featureorder.add("test");
        for (String n : names) {
          if (!"test".equals(n)) {
            featureorder.add(n);
          }
        }
      }
      else {
        featureorder.addAll(names);
      }
      // Station special case, mirroring test's: its transport wrap must
      // sit immediately outside the base transport (inside retry/cache/
      // netsim), so map-form activation hoists it to just after test -
      // or first, when no test entry exists. Without this the sorted
      // default would init station last and wrap OUTSIDE the recording
      // features, turning its wire-truth events into fiction.
      int si = featureorder.indexOf("station");
      if (0 <= si) {
        featureorder.remove(si);
        featureorder.add(featureorder.indexOf("test") + 1, "station");
      }
    }

    Map<String, Object> derived = new LinkedHashMap<>();
    Map<String, Object> derivedClean = new LinkedHashMap<>();
    if (!"".equals(keyre)) {
      derivedClean.put("keyre", keyre);
    }
    derived.put("clean", derivedClean);
    derived.put("featureorder", featureorder);
    opts.put("__derived__", derived);

    return opts;
  }
}
