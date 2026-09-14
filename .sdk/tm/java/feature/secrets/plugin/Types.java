// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Types.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Shared types and the value helpers every module reads data through.
 *
 * <p>Deliberately small: the design's §19 budget says the library owns
 * naming, configuration, lifecycle, ordering, binding and teardown, and
 * nothing else.
 *
 * <p>JAVA RAISES, so this port follows the CANONICAL rather than go: a
 * failing call throws {@link PluginException}, which carries the §12 code
 * the corpus compares by. Go and rust return their errors because their
 * languages have no other idiom; java has one, and using it keeps the
 * control flow the same shape as the typescript this is a port of.
 */
public final class Types {

  private Types() {}

  /**
   * §5.1's seven statuses, and no more. A port that adds an eighth is
   * diverging. {@code loading} and {@code closing} are observable only
   * from inside a callback or from another thread.
   */
  public static final List<String> STATUSES =
      List.of("declared", "loaded", "pending", "live", "failed", "loading", "closing");

  /**
   * §12's detail fields, IN THIS FIXED ORDER.
   *
   * <p>The order is part of the contract, not a formatting preference. An
   * earlier draft named six fields while other sections promised
   * diagnostics that had nowhere to go, which would have left each port
   * inventing its own order and breaking message parity.
   */
  public static final List<String> DETAIL_ORDER =
      List.of(
          "host", "ref", "name", "tag", "point", "key", "capability", "range", "version", "match",
          "candidates", "cycle", "holders", "refs", "path", "cause");

  /**
   * {@code plugin/<code>: <text> [<key>=<value> ...]}
   *
   * <p>Values render as COMPACT JSON, so a value containing a space or a
   * bracket cannot break the parse, and a list renders as a JSON array.
   * The bracket is absent entirely when no field applies.
   */
  public static String formaterror(String code, String text, Object details) {
    List<String> parts = new ArrayList<>();
    for (String key : DETAIL_ORDER) {
      if (!has(details, key)) {
        continue;
      }
      parts.add(key + "=" + Json.write(get(details, key)));
    }
    String tail = parts.isEmpty() ? "" : " [" + String.join(" ", parts) + "]";
    return "plugin/" + code + ": " + text + tail;
  }

  /** Throw a §12 error. One spelling, so every raise site reads the same. */
  public static void fail(String code, String text, Object details) {
    throw new PluginException(code, text, details);
  }

  /**
   * The §12 code of a throwable, or "" for one this library did not raise.
   * The corpus compares by code, so the driver needs one place that knows
   * how to read it.
   */
  public static String codeof(Throwable err) {
    return err instanceof PluginException ? ((PluginException) err).code : "";
  }

  /** A detail map, spelled once rather than at forty call sites. */
  public static Map<String, Object> details(Object... pairs) {
    Map<String, Object> out = new TreeMap<>();
    for (int i = 0; i + 1 < pairs.length; i += 2) {
      out.put((String) pairs[i], pairs[i + 1]);
    }
    return out;
  }

  // -- the value helpers ----------------------------------------------

  @SuppressWarnings("unchecked")
  public static Map<String, Object> map(Object value) {
    return value instanceof Map ? (Map<String, Object>) value : null;
  }

  @SuppressWarnings("unchecked")
  public static List<Object> list(Object value) {
    return value instanceof List ? (List<Object>) value : null;
  }

  public static String str(Object value) {
    return value instanceof String ? (String) value : null;
  }

  public static Double num(Object value) {
    return value instanceof Double ? (Double) value : null;
  }

  /**
   * An INTEGER, and only when the value is one. §7's band is an integer
   * the document wrote as one; {@code true} and {@code "2"} are not bands,
   * and a port that coerced them would accept documents the canonical
   * rejects.
   */
  public static Long asint(Object value) {
    Double n = num(value);
    if (null == n || n != Math.floor(n) || Double.isInfinite(n)) {
      return null;
    }
    return (long) (double) n;
  }

  /** The value at a key, or null. Absence and null read the same here. */
  public static Object get(Object node, String key) {
    Map<String, Object> m = map(node);
    return null == m ? null : m.get(key);
  }

  /** PRESENCE, which is what distinguishes an authored null from absence. */
  public static boolean has(Object node, String key) {
    Map<String, Object> m = map(node);
    return null != m && m.containsKey(key);
  }

  public static Object at(Object node, int index) {
    List<Object> l = list(node);
    return null == l || l.size() <= index ? null : l.get(index);
  }

  /** The keys of a map, sorted - which a TreeMap already is. */
  public static List<String> keys(Object node) {
    Map<String, Object> m = map(node);
    return null == m ? new ArrayList<>() : new ArrayList<>(m.keySet());
  }

  public static Map<String, Object> newmap() {
    return new TreeMap<>();
  }

  /**
   * Ruby's truthiness, which is not java's `if`: present, and not {@code
   * false}. {@code 0}, {@code ""} and {@code []} are all values the corpus
   * distinguishes from absence.
   */
  public static boolean truthy(Object value) {
    return null != value && !Boolean.FALSE.equals(value);
  }

  /**
   * JSON equality: same type, then same value.
   *
   * <p>{@code true} is not {@code 1} and {@code 1} is not {@code "1"} -
   * `capability/match` has an entry for each direction. JAVA NEEDS NO
   * GUARD FOR THAT, because {@code Boolean.equals(Double)} is false and so
   * is {@code Double.equals(String)}; the guard php, perl and lua each
   * carry is unreachable here, and a mutation deleting one would be a
   * non-mutation. What java DOES need is the one-number-type rule kept at
   * the parser: every number is a {@link Double}, so an {@link Integer}
   * never enters the data to compare unequal against its own literal.
   */
  public static boolean same(Object a, Object b) {
    Map<String, Object> ma = map(a);
    Map<String, Object> mb = map(b);
    if (null != ma || null != mb) {
      if (null == ma || null == mb || ma.size() != mb.size()) {
        return false;
      }
      for (Map.Entry<String, Object> e : ma.entrySet()) {
        if (!mb.containsKey(e.getKey()) || !same(e.getValue(), mb.get(e.getKey()))) {
          return false;
        }
      }
      return true;
    }
    List<Object> la = list(a);
    List<Object> lb = list(b);
    if (null != la || null != lb) {
      if (null == la || null == lb || la.size() != lb.size()) {
        return false;
      }
      for (int i = 0; i < la.size(); i++) {
        if (!same(la.get(i), lb.get(i))) {
          return false;
        }
      }
      return true;
    }
    return null == a ? null == b : a.equals(b);
  }

  /**
   * A deep copy. NOT named `clone`: `Object.clone()` is inherited by every
   * class, so a static import of a same-named helper silently resolves to
   * the instance method and does not compile.
   */
  public static Object copy(Object value) {
    Map<String, Object> m = map(value);
    if (null != m) {
      Map<String, Object> out = newmap();
      for (Map.Entry<String, Object> e : m.entrySet()) {
        out.put(e.getKey(), copy(e.getValue()));
      }
      return out;
    }
    List<Object> l = list(value);
    if (null != l) {
      List<Object> out = new ArrayList<>();
      for (Object item : l) {
        out.add(copy(item));
      }
      return out;
    }
    return value;
  }

  /** A list of strings as a list of values, for a detail field. */
  public static List<Object> strings(List<String> items) {
    return new ArrayList<>(items);
  }
}
