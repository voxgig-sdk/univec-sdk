package JAVAPACKAGE.utility;

import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collection;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.BiFunction;
import java.util.function.Consumer;
import java.util.function.Function;
import java.util.function.Supplier;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Entity;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.Schema;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.SdkError;
import JAVAPACKAGE.core.Utility;
import JAVAPACKAGE.utility.struct.Struct;

// Everything that leaves the pipeline passes through clean: the error, the
// explain record, the serialised context, and whatever a feature emits.
// Two layers: every registered secret VALUE (and its encoded forms) is
// replaced wherever it appears in a string, and every value under a
// sensitive KEY name is masked whatever it holds. Inside the pipeline data
// stays raw, so a hook can still read the header it must add to.
//
// The configuration is the derived block MakeOptions builds
// (`options.__derived__.clean`): active, keys, values, mask, hint, min. It
// is a map so the registry can grow after construction - the auth step and
// the features register what they handle later.
@SuppressWarnings({"unchecked"})
final class Clean {

  private static final int MAXDEPTH = 32;
  private static final String CIRCULAR = "[circular]";
  private static final String DEFAULT_MASK = "[redacted]";

  // A function has no place in a plain-data copy; the snapshot omits it.
  private static final Object DROP = new Object();

  private Clean() {}

  // A context without options (makeError is reached with a bare one) falls
  // back to the schema defaults, so nothing leaves raw for want of a
  // constructor.
  static Map<String, Object> cleanConfig(Context ctx) {
    Object derived = null;
    if (ctx != null && ctx.options != null) {
      derived = Struct.getpath(ctx.options, List.of("__derived__", "clean"));
    }
    if (derived instanceof Map) {
      return (Map<String, Object>) derived;
    }
    return makeCleanConfig(Helpers.toMapAny(Schema.optspec().get("clean")));
  }

  static Map<String, Object> makeCleanConfig(Map<String, Object> cleanopts) {
    Map<String, Object> opts = cleanopts == null ? new LinkedHashMap<>() : cleanopts;
    // Read without the monitor add() holds, by a clean or a request copying
    // the options: each read sees the list the last registration put.
    Map<String, Object> cfg = new ConcurrentHashMap<>();
    cfg.put("active", !Boolean.FALSE.equals(opts.get("active")));
    cfg.put("keys", splitkeys(opts.get("keys")));
    cfg.put("values", new ArrayList<String>());
    cfg.put("mask", opts.get("mask") instanceof String ? opts.get("mask") : DEFAULT_MASK);
    cfg.put("hint", count(opts.get("hint"), 0));
    cfg.put("min", Math.max(1, count(opts.get("min"), 4)));
    return cfg;
  }

  private static String normkey(Object key) {
    return String.valueOf(key).toLowerCase(Locale.ROOT).replace("-", "").replace("_", "");
  }

  private static List<String> splitkeys(Object keys) {
    List<String> out = new ArrayList<>();
    for (String k : String.valueOf(keys == null ? "" : keys).split("\\s*,\\s*")) {
      String nk = normkey(k);
      if (!"".equals(nk)) {
        out.add(nk);
      }
    }
    return out;
  }

  // The comma-separated literal values a caller registers; a list is taken
  // as-is for a caller that has one.
  static List<String> splitvalues(Object values) {
    List<String> out = new ArrayList<>();
    if (values instanceof List) {
      for (Object v : (List<Object>) values) {
        if (v instanceof String) {
          out.add((String) v);
        }
      }
      return out;
    }
    for (String v : String.valueOf(values == null ? "" : values).split("\\s*,\\s*")) {
      if (!"".equals(v)) {
        out.add(v);
      }
    }
    return out;
  }

  // The spec carries numbers as strings, so every target reads it alike.
  private static int count(Object val, int dflt) {
    if (val == null) {
      return dflt;
    }
    double d;
    if (val instanceof Number) {
      d = ((Number) val).doubleValue();
    }
    else {
      String s = String.valueOf(val).trim();
      if ("".equals(s)) {
        return 0;
      }
      try {
        d = Double.parseDouble(s);
      }
      catch (NumberFormatException e) {
        return dflt;
      }
    }
    if (Double.isNaN(d) || Double.isInfinite(d) || d < 0) {
      return dflt;
    }
    return (int) Math.floor(d);
  }

  private static boolean active(Map<String, Object> cfg) {
    return !Boolean.FALSE.equals(cfg.get("active"));
  }

  private static List<String> keys(Map<String, Object> cfg) {
    return cfg.get("keys") instanceof List ? (List<String>) cfg.get("keys") : List.of();
  }

  private static List<String> values(Map<String, Object> cfg) {
    Object values = cfg.get("values");
    return values instanceof List ? (List<String>) values : List.of();
  }

  private static String mask(Map<String, Object> cfg) {
    return cfg.get("mask") instanceof String ? (String) cfg.get("mask") : DEFAULT_MASK;
  }

  private static int hint(Map<String, Object> cfg) {
    return count(cfg.get("hint"), 0);
  }

  private static int min(Map<String, Object> cfg) {
    return Math.max(1, count(cfg.get("min"), 4));
  }

  // The encoded forms a value travels in: Basic and Bearer both carry base64,
  // a query credential is percent-encoded (both the wire form Struct.escurl
  // sends and the JavaScript form a peer SDK sends), and a JSON dump escapes
  // it.
  private static List<String> forms(String value) {
    List<String> out = new ArrayList<>();
    out.add(value);
    byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
    addForm(out, Base64.getEncoder().encodeToString(bytes));
    String enc = URLEncoder.encode(value, StandardCharsets.UTF_8);
    addForm(out, enc.replace("+", "%20"));
    addForm(out, enc.replace("+", "%20").replace("%21", "!").replace("%27", "'")
        .replace("%28", "(").replace("%29", ")").replace("%7E", "~"));
    String json = Struct.jsonify(value);
    if (json.length() >= 2) {
      addForm(out, json.substring(1, json.length() - 1));
    }
    return out;
  }

  private static void addForm(List<String> out, String form) {
    if (!"".equals(form) && !out.contains(form)) {
      out.add(form);
    }
  }

  // Register a secret value. Idempotent; shorter than `min` is not a secret
  // the SDK can mask without blanking ordinary text. Requests on other
  // threads clean while one registers, so a registration publishes a new
  // list and never changes a published one.
  static void add(Map<String, Object> cfg, Object value) {
    if (!(value instanceof String) || ((String) value).length() < min(cfg)) {
      return;
    }
    synchronized (cfg) {
      List<String> values = new ArrayList<>(values(cfg));
      int had = values.size();
      for (String form : forms((String) value)) {
        if (form.length() >= min(cfg) && !values.contains(form)) {
          values.add(form);
        }
      }
      if (had < values.size()) {
        values.sort((a, b) -> b.length() - a.length());
        cfg.put("values", List.copyOf(values));
      }
    }
  }

  static void cleanAdd(Context ctx, Object value) {
    add(cleanConfig(ctx), value);
  }

  // Every scalar under a sensitive name in the options, at any depth and of
  // any shape: a credential mistyped as a map or a number is still one, and
  // a message can quote it. A key under `feature` names a feature, not a
  // field, so a feature called secrets does not make its settings secret.
  // Entity blocks (entity settings, seeded records) hold no credential, and
  // nor do rbac's rules, keyed by entity and operation names.
  static void addSensitiveOptions(Map<String, Object> cfg, Map<String, Object> opts) {
    IdentityHashMap<Object, Boolean> seen = new IdentityHashMap<>();
    for (Map.Entry<String, Object> e : opts.entrySet()) {
      String key = e.getKey();
      Object val = e.getValue();
      boolean under = sensitive(cfg, key);
      if ("entity".equals(key)) {
        continue;
      }
      if ("feature".equals(key) && val instanceof Map) {
        for (Map.Entry<?, ?> f : ((Map<?, ?>) val).entrySet()) {
          addSensitive(cfg, plain(f.getValue(), String.valueOf(f.getKey())), under, 2, seen);
        }
      }
      else if ("feature".equals(key) && val instanceof List) {
        for (Object fopts : (List<?>) val) {
          Object name = fopts instanceof Map ? ((Map<?, ?>) fopts).get("name") : null;
          addSensitive(cfg, plain(fopts, name instanceof String ? (String) name : null),
              under, 2, seen);
        }
      }
      else {
        addSensitive(cfg, "test".equals(key) ? plain(val, null) : val, under, 1, seen);
      }
    }
  }

  private static Object plain(Object block, String name) {
    if (!(block instanceof Map)) {
      return block;
    }
    Map<Object, Object> out = new LinkedHashMap<>((Map<?, ?>) block);
    out.remove("entity");
    if ("rbac".equals(name)) {
      out.remove("rules");
    }
    return out;
  }

  private static void addSensitive(Map<String, Object> cfg, Object val, boolean under,
      int depth, IdentityHashMap<Object, Boolean> seen) {
    if (val == null || MAXDEPTH <= depth) {
      return;
    }
    if (val instanceof String || val instanceof Number) {
      if (under) {
        add(cfg, String.valueOf(val));
        add(cfg, Struct.stringify(val));
      }
      return;
    }
    if (seen.containsKey(val)) {
      return;
    }
    seen.put(val, Boolean.TRUE);
    if (val instanceof Map) {
      for (Map.Entry<?, ?> e : ((Map<?, ?>) val).entrySet()) {
        addSensitive(cfg, e.getValue(), under || sensitive(cfg, e.getKey()), depth + 1, seen);
      }
    }
    else if (val instanceof Collection || val instanceof Object[]) {
      Object[] items = val instanceof Object[] ? (Object[]) val : ((Collection<?>) val).toArray();
      for (Object item : items) {
        addSensitive(cfg, item, under, depth + 1, seen);
      }
    }
  }

  private static String maskValue(Map<String, Object> cfg, String value) {
    int hint = hint(cfg);
    if (0 < hint && value.length() > 2 * hint) {
      return mask(cfg) + value.substring(value.length() - hint);
    }
    return mask(cfg);
  }

  static String cleanString(Map<String, Object> cfg, String text) {
    String out = text;
    for (String value : values(cfg)) {
      if (out.contains(value)) {
        out = out.replace(value, maskValue(cfg, value));
      }
    }
    return out;
  }

  static boolean sensitive(Map<String, Object> cfg, Object key) {
    if (key == null || key instanceof Number) {
      return false;
    }
    String nk = normkey(key);
    for (String k : keys(cfg)) {
      if (nk.contains(k)) {
        return true;
      }
    }
    return false;
  }

  private static boolean isFunction(Object val) {
    return val instanceof Function || val instanceof Supplier || val instanceof Consumer
        || val instanceof BiFunction || val instanceof Runnable
        || val instanceof Utility.CtxFn || val instanceof Utility.CleanFn
        || val instanceof Utility.CleanAddFn || val instanceof Utility.MakeErrorFn
        || val instanceof Utility.FeatureFn || val instanceof Utility.HookFn
        || val instanceof Utility.FetcherFn || val instanceof Utility.MakeContextFn
        || val instanceof Utility.ParamFn
        || val.getClass().isSynthetic();
  }

  private static boolean isScalar(Object val) {
    return val instanceof Number || val instanceof Boolean || val instanceof Character
        || val instanceof Enum;
  }

  private static String stackOf(Throwable err) {
    StringWriter sw = new StringWriter();
    err.printStackTrace(new PrintWriter(sw));
    return sw.toString();
  }

  // A plain-data copy of what is about to leave. Java has no toJSON hook, so
  // the SDK's own types are read the way a serialiser would: a context as
  // its record, an entity as its data, an error as its message and stack,
  // and any other object through its public fields. Functions are dropped,
  // cycles are cut, and no live object is shared with the copy - masking the
  // copy must never mask the pipeline's own spec.
  private static Object snapshot(Map<String, Object> cfg, Object val, Object key, int depth,
      IdentityHashMap<Object, Boolean> seen) {
    if (val == null || val == Struct.UNDEF) {
      return null;
    }

    if (val instanceof String) {
      return sensitive(cfg, key) ? maskValue(cfg, (String) val) : cleanString(cfg, (String) val);
    }

    if (isFunction(val) || val instanceof SdkClient || val instanceof Utility) {
      return DROP;
    }

    if (isScalar(val)) {
      return sensitive(cfg, key) ? mask(cfg) : val;
    }

    if (MAXDEPTH <= depth || seen.containsKey(val)) {
      return CIRCULAR;
    }

    if (sensitive(cfg, key)) {
      return mask(cfg);
    }

    seen.put(val, Boolean.TRUE);
    try {
      if (val instanceof Map) {
        Map<String, Object> out = new LinkedHashMap<>();
        for (Map.Entry<?, ?> e : ((Map<?, ?>) val).entrySet()) {
          String k = String.valueOf(e.getKey());
          Object v = snapshot(cfg, e.getValue(), k, depth + 1, seen);
          if (v != DROP) {
            out.put(cleanName(cfg, out, k), v);
          }
        }
        return out;
      }

      if (val instanceof Collection || val instanceof Object[]) {
        List<Object> out = new ArrayList<>();
        Object[] items = val instanceof Object[] ? (Object[]) val : ((Collection<?>) val).toArray();
        for (int i = 0; i < items.length; i++) {
          Object v = snapshot(cfg, items[i], i, depth + 1, seen);
          out.add(v == DROP ? null : v);
        }
        return out;
      }

      if (val instanceof Context) {
        return snapshot(cfg, ((Context) val).record(), key, depth + 1, seen);
      }

      if (val instanceof Entity) {
        Object data = ((Entity) val).data();
        Map<String, Object> out = new LinkedHashMap<>();
        Object v = snapshot(cfg, data, key, depth + 1, seen);
        if (v instanceof Map) {
          out.putAll((Map<String, Object>) v);
        }
        out.put("voxgig$entity", ((Entity) val).getName());
        return out;
      }

      if (val instanceof Throwable) {
        Throwable err = (Throwable) val;
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("message", cleanString(cfg, String.valueOf(err.getMessage())));
        out.put("stack", cleanString(cfg, stackOf(err)));
        out.putAll(fields(cfg, val, depth, seen));
        return out;
      }

      return fields(cfg, val, depth, seen);
    }
    finally {
      seen.remove(val);
    }
  }

  private static Map<String, Object> fields(Map<String, Object> cfg, Object val, int depth,
      IdentityHashMap<Object, Boolean> seen) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (Field f : val.getClass().getFields()) {
      if (Modifier.isStatic(f.getModifiers())) {
        continue;
      }
      Object fv;
      try {
        fv = f.get(val);
      }
      catch (ReflectiveOperationException | RuntimeException e) {
        continue;
      }
      Object v = snapshot(cfg, fv, f.getName(), depth + 1, seen);
      if (v != DROP) {
        out.put(cleanName(cfg, out, f.getName()), v);
      }
    }
    return out;
  }

  // A registered value used as a property name is masked like any other
  // string; names that mask alike take a counter, so none is lost.
  private static String cleanName(Map<String, Object> cfg, Map<String, Object> out, String key) {
    String name = cleanString(cfg, key);
    if (name.equals(key) || !out.containsKey(name)) {
      return name;
    }
    int i = 1;
    while (out.containsKey(name + "#" + i)) {
      i++;
    }
    return name + "#" + i;
  }

  // Clean a value on its way out. A string is redacted; the SDK's own error
  // is redacted IN PLACE (it is about to be thrown, and its identity matters
  // to the caller); anything else comes back as a masked plain-data copy.
  // A foreign exception's message cannot be rewritten, so it is replaced by
  // an SDK error with the cleaned message and the original frames; the
  // original is not attached, as a printed stack trace would show it.
  static Object cleanWith(Map<String, Object> cfg, Object val) {
    if (!active(cfg)) {
      return val;
    }

    if (val instanceof String) {
      return cleanString(cfg, (String) val);
    }

    if (val instanceof SdkError) {
      SdkError err = (SdkError) val;
      err.msg = cleanString(cfg, String.valueOf(err.msg));
      if (err.code != null) {
        err.code = cleanString(cfg, err.code);
      }
      err.result = cleanField(cfg, "result", err.result);
      err.spec = cleanField(cfg, "spec", err.spec);
      return err;
    }

    if (val instanceof Throwable) {
      Throwable err = (Throwable) val;
      String msg = err.getMessage() == null ? String.valueOf(err) : err.getMessage();
      SdkError out = new SdkError("", cleanString(cfg, msg), null);
      out.setStackTrace(err.getStackTrace());
      return out;
    }

    Object out = snapshot(cfg, val, null, 0, new IdentityHashMap<>());
    return out == DROP ? null : out;
  }

  private static Object cleanField(Map<String, Object> cfg, String key, Object val) {
    if (val instanceof String) {
      return sensitive(cfg, key) ? maskValue(cfg, (String) val) : cleanString(cfg, (String) val);
    }
    if (val == null || isScalar(val)) {
      return val;
    }
    Object out = snapshot(cfg, val, key, 1, new IdentityHashMap<>());
    return out == DROP ? null : out;
  }

  static Object clean(Context ctx, Object val) {
    return cleanWith(cleanConfig(ctx), val);
  }

  // Is this key name sensitive under the context's clean configuration?
  static boolean cleanKey(Context ctx, Object key) {
    return sensitive(cleanConfig(ctx), key);
  }

  // The explain record is the caller's own map (Context keeps the instance
  // it was handed), so the cleaned copy is written back into it rather than
  // replacing it, or the caller would keep reading the raw one.
  static void cleanExplain(Context ctx) {
    Map<String, Object> explain = ctx.ctrl == null ? null : ctx.ctrl.explain;
    if (explain == null) {
      return;
    }
    Map<String, Object> cleaned = Helpers.toMapAny(clean(ctx, explain));
    if (cleaned != null && cleaned != explain) {
      explain.clear();
      explain.putAll(cleaned);
    }
  }
}
