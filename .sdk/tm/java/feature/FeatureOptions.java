package JAVAPACKAGE.feature;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.IntConsumer;
import java.util.function.LongSupplier;

// Shared option readers for the feature implementations. Feature options
// arrive as Map<String,Object> (from SDK options or test harnesses), so
// numeric values may be Integer, Long or Double and callbacks arrive as
// functional-interface instances. These helpers normalise access and supply
// defaults, mirroring the `null == opts.x ? def : opts.x` pattern of the
// ts features.
@SuppressWarnings({"unchecked"})
final class FeatureOptions {

  private FeatureOptions() {}

  static boolean foptBool(Map<String, Object> options, String key, boolean def) {
    if (options == null) {
      return def;
    }
    Object v = options.get(key);
    if (v instanceof Boolean) {
      return (Boolean) v;
    }
    return def;
  }

  static int foptInt(Map<String, Object> options, String key, int def) {
    if (options == null) {
      return def;
    }
    Object v = options.get(key);
    if (v instanceof Number) {
      return ((Number) v).intValue();
    }
    return def;
  }

  static double foptNum(Map<String, Object> options, String key, double def) {
    if (options == null) {
      return def;
    }
    Object v = options.get(key);
    if (v instanceof Number) {
      return ((Number) v).doubleValue();
    }
    return def;
  }

  static String foptStr(Map<String, Object> options, String key, String def) {
    if (options == null) {
      return def;
    }
    Object v = options.get(key);
    if (v instanceof String && !"".equals(v)) {
      return (String) v;
    }
    return def;
  }

  static Map<String, Object> foptMap(Map<String, Object> options, String key) {
    if (options == null) {
      return null;
    }
    Object v = options.get(key);
    if (v instanceof Map) {
      return (Map<String, Object>) v;
    }
    return null;
  }

  static List<Object> foptList(Map<String, Object> options, String key) {
    if (options == null) {
      return null;
    }
    Object v = options.get(key);
    if (v instanceof List) {
      return (List<Object>) v;
    }
    return null;
  }

  // foptStrList reads a list option as strings.
  static List<String> foptStrList(Map<String, Object> options, String key) {
    List<Object> raw = foptList(options, key);
    if (raw == null) {
      return null;
    }
    List<String> out = new ArrayList<>();
    for (Object v : raw) {
      if (v instanceof String) {
        out.add((String) v);
      }
    }
    return out;
  }

  // foptSleep returns the injectable sleep (option "sleep": IntConsumer of
  // ms), defaulting to a real Thread.sleep. Injected clocks keep tests
  // deterministic.
  static IntConsumer foptSleep(Map<String, Object> options) {
    if (options != null && options.get("sleep") instanceof IntConsumer) {
      return (IntConsumer) options.get("sleep");
    }
    return (ms) -> {
      if (ms > 0) {
        try {
          Thread.sleep(ms);
        }
        catch (InterruptedException e) {
          Thread.currentThread().interrupt();
        }
      }
    };
  }

  // foptNow returns the injectable clock (option "now": LongSupplier of ms),
  // defaulting to the wall clock.
  static LongSupplier foptNow(Map<String, Object> options) {
    if (options != null && options.get("now") instanceof LongSupplier) {
      return (LongSupplier) options.get("now");
    }
    return System::currentTimeMillis;
  }

  // fheaderGet reads a header value case-insensitively; null when absent.
  // (JSON null header values are indistinguishable from absent here, same
  // as the go donor's found=false.)
  static Object fheaderGet(Map<String, Object> headers, String name) {
    if (headers == null) {
      return null;
    }
    for (Map.Entry<String, Object> e : headers.entrySet()) {
      if (e.getKey() != null && e.getKey().equalsIgnoreCase(name)) {
        return e.getValue();
      }
    }
    return null;
  }

  static boolean fheaderHas(Map<String, Object> headers, String name) {
    if (headers == null) {
      return false;
    }
    for (String k : headers.keySet()) {
      if (k != null && k.equalsIgnoreCase(name)) {
        return true;
      }
    }
    return false;
  }

  // fheaderSetDefault sets a header only when no case-insensitive variant of
  // it exists already (never clobber a caller-provided value).
  static void fheaderSetDefault(Map<String, Object> headers, String name, String value) {
    if (headers == null) {
      return;
    }
    if (fheaderHas(headers, name)) {
      return;
    }
    headers.put(name, value);
  }

  // fresStatus extracts the numeric status from a transport-shaped response
  // (map with a "status" entry). Returns -1 when absent or non-numeric.
  static int fresStatus(Object res) {
    if (!(res instanceof Map)) {
      return -1;
    }
    Object s = ((Map<String, Object>) res).get("status");
    if (s instanceof Number) {
      return ((Number) s).intValue();
    }
    return -1;
  }

  // fresHeader reads a header from a transport-shaped response,
  // case-insensitively, as a string ("" when absent).
  static String fresHeader(Object res, String name) {
    if (!(res instanceof Map)) {
      return "";
    }
    Object headers = ((Map<String, Object>) res).get("headers");
    if (!(headers instanceof Map)) {
      return "";
    }
    Object v = fheaderGet((Map<String, Object>) headers, name);
    return v instanceof String ? (String) v : "";
  }

  // fparseInt parses a decimal string; def when unparseable.
  static int fparseInt(String s, int def) {
    try {
      return Integer.parseInt(s.trim());
    }
    catch (RuntimeException e) {
      return def;
    }
  }
}
