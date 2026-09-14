// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Config.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.asint;
import static JAVAPACKAGE.feature.secrets.plugin.Types.copy;
import static JAVAPACKAGE.feature.secrets.plugin.Types.details;
import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.get;
import static JAVAPACKAGE.feature.secrets.plugin.Types.has;
import static JAVAPACKAGE.feature.secrets.plugin.Types.keys;
import static JAVAPACKAGE.feature.secrets.plugin.Types.list;
import static JAVAPACKAGE.feature.secrets.plugin.Types.map;
import static JAVAPACKAGE.feature.secrets.plugin.Types.newmap;
import static JAVAPACKAGE.feature.secrets.plugin.Types.num;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The declarative document (§9): normalization, and the ten-level
 * precedence ladder.
 *
 * <p>TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
 *
 * <p>{@code normalizeConfig} normalizes STRUCTURE and ENTRY KEYS. It does
 * not merge options, and cannot: §9.4 makes merge behaviour a property of
 * the definition's option SHAPE, which normalization has never seen. A
 * normalizer that flattened the option layers would make {@code $MERGE:
 * append} unimplementable at load time, because the layers it must
 * concatenate would already be collapsed.
 *
 * <p>{@code resolveOptions} applies the ladder, and it is the only place
 * that knows the shape.
 */
public final class Config {

  private Config() {}

  public static final List<String> MERGE_WORDS = List.of("replace", "append");

  public static Map<String, Object> normalizeConfig(Object input) {
    Object doc = get(input, "doc");
    Object keys = get(input, "keys");
    String ikey = null == str(get(keys, "instance")) ? "instance" : str(get(keys, "instance"));
    String dkey = null == str(get(keys, "default")) ? "default" : str(get(keys, "default"));
    Object reserved = get(input, "reserved");
    Object profile = get(input, "profile");

    // The rename is applied at TWO PLACES AND NO OTHERS: the document
    // root, and every profile.<name> overlay root (§9.1). A rename applied
    // only at the root would leave `profile.prod.sdk` untranslated and
    // silently drop every environment override the host depends on.
    // Recursing further would be worse: option data is the definition's.
    Object baseinst = get(doc, ikey);
    Object basedef = get(doc, dkey);

    Object overlay = null == str(profile) ? null : get(get(doc, "profile"), str(profile));
    if (null == map(overlay)) {
      overlay = newmap();
    }
    Object overinst = get(overlay, ikey);
    Object overdef = get(overlay, dkey);

    // Entry layers, base then overlay, each as {ref -> entry} plus the
    // order the form implies.
    Entries base = entries(baseinst);
    Entries over = entries(overinst);

    List<List<String>> groups = new ArrayList<>();
    groups.add(new ArrayList<>(base.map.keySet()));
    groups.add(new ArrayList<>(over.map.keySet()));
    groups.add(keys(basedef));
    groups.add(keys(overdef));
    for (List<String> group : groups) {
      for (String r : group) {
        checkreserved(r, reserved);
      }
    }

    // A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the hard
    // way: deriving order from a partial array silently dropped
    // config-activated features. Refs in the base but absent from the
    // overlay still load, in sorted position AFTER the listed ones. A
    // profile may also INTRODUCE a ref the base never declared.
    List<String> order = new ArrayList<>();
    for (String r : over.order) {
      if (!order.contains(r)) {
        order.add(r);
      }
    }
    for (String r : base.order) {
      if (!order.contains(r)) {
        order.add(r);
      }
    }

    Map<String, Object> instance = newmap();
    for (int i = 0; i < order.size(); i++) {
      String ref = order.get(i);
      Object b = base.map.get(ref);
      Object o = over.map.get(ref);

      // MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
      // (§9.3). A safety rule, not a tidiness one: if the overlay had its
      // defaults filled in before merging it would carry a synthesized
      // active:true and overwrite a base's false - silently re-enabling a
      // deliberately disabled integration in production.
      Object active = pick(o, "active", pick(b, "active", Boolean.TRUE));
      Object start = pick(o, "start", pick(b, "start", "eager"));
      Object block = pick(o, "order", pick(b, "order", null));

      // Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
      String nm = Refs.refname(ref);
      List<Object> layers = new ArrayList<>();
      List<Object> sources = new ArrayList<>();
      sources.add(get(basedef, nm));
      sources.add(b);
      sources.add(get(overdef, nm));
      sources.add(o);
      for (Object src : sources) {
        if (has(src, "options")) {
          layers.add(get(src, "options"));
        }
      }

      Map<String, Object> ent = newmap();
      ent.put("pos", (double) i);
      ent.put("active", active);
      ent.put("start", start);
      ent.put("optionlayers", layers);
      if (null != block) {
        ent.put("order", block);
      }
      instance.put(ref, ent);
    }

    // `default` DECLARES NOTHING (§9.3). It is a base for every instance
    // of that definition; it does not create one, and an entry for a name
    // with no instances is inert rather than an error - which is what
    // makes a shared library of defaults shippable.
    Map<String, Object> defout = newmap();
    for (String n : keys(basedef)) {
      defout.put(n, get(basedef, n));
    }
    for (String n : keys(overdef)) {
      defout.put(n, get(overdef, n));
    }

    Map<String, Object> out = newmap();
    out.put("instance", instance);
    out.put("order", Types.strings(order));
    out.put("default", defout);
    return out;
  }

  /**
   * Both document forms reduce to {ref -&gt; entry} plus the order the
   * form implies: array POSITION for the array form, sorted refs for the
   * map form.
   */
  private static final class Entries {
    final Map<String, Object> map = new LinkedHashMap<>();
    final List<String> order = new ArrayList<>();
  }

  private static Entries entries(Object src) {
    Entries out = new Entries();
    if (null == src) {
      return out;
    }

    List<Object> items = list(src);
    if (null != items) {
      for (Object item : items) {
        String ref = Refs.canonRef(get(item, "ref"));
        out.map.put(ref, item);
        out.order.add(ref);
      }
      return out;
    }

    // Map-form refs arrive as KEYS, through a different path than an array
    // element's `ref` field - and must canonicalize the same way.
    for (String key : keys(src)) {
      out.map.put(Refs.canonRef(key), get(src, key));
    }
    // Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
    // sort identically under all three, so only mixed input discriminates:
    // '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. String's
    // natural order is exactly that.
    List<String> sorted = new ArrayList<>(out.map.keySet());
    sorted.sort(null);
    out.order.addAll(sorted);
    return out;
  }

  /**
   * §9.1: reservation is all-or-nothing per NAME, so the tagged forms go
   * too. A configuration surface that can disable the thing reading it is
   * not a surface, it is a trap.
   */
  private static void checkreserved(String ref, Object reserved) {
    List<Object> list = list(reserved);
    if (null == list || list.isEmpty()) {
      return;
    }
    if (!list.contains(Refs.refname(ref))) {
      return;
    }
    fail("plugin_ref_reserved", "ref is reserved by the host: " + ref, details("ref", ref));
  }

  /**
   * PRESENCE decides, not truthiness and not null. A JSON {@code null} is
   * a present value in JavaScript ({@code undefined !== null}), so it must
   * be one here.
   */
  private static Object pick(Object src, String key, Object dflt) {
    return has(src, key) ? get(src, key) : dflt;
  }

  // -------------------------------------------------------------------
  // resolveOptions - §9.3's ten levels, and 9.4's directives
  // -------------------------------------------------------------------

  public static Map<String, Object> resolveOptions(Object input) {
    Object shape = get(input, "shape");
    checkShape(shape);

    String ref = Refs.canonRef(get(input, "ref"));
    String name = Refs.refname(ref);
    Object doc = get(input, "doc");
    Object profile = get(input, "profile");

    Object overlay = null == str(profile) ? null : get(get(doc, "profile"), str(profile));
    if (null == map(overlay)) {
      overlay = newmap();
    }

    // ONE ordered merge, lowest to highest. Levels 3-6 are not two
    // namespaces collapsed separately and composed afterwards: that
    // inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
    // SPECIFICITY, so a prod per-definition default would lose to a base
    // instance value.
    List<Object> layers = new ArrayList<>();
    layers.add(defaultsof(shape)); // 1
    layers.add(get(input, "hostdefaults")); // 2
    layers.add(optsof(get(doc, "default"), name)); // 3
    layers.add(optsof(get(doc, "instance"), ref)); // 4
    layers.add(optsof(get(overlay, "default"), name)); // 5
    layers.add(optsof(get(overlay, "instance"), ref)); // 6
    layers.add(get(input, "env")); // 7
    layers.add(get(input, "hostoptions")); // 8
    layers.add(get(input, "loadoptions")); // 9
    layers.add(get(input, "patch")); // 10

    Object out = newmap();
    for (Object layer : layers) {
      if (null == layer) {
        continue;
      }
      out = mergeone(out, layer, shape);
    }
    return map(out);
  }

  /** The shape's non-directive values are the level-1 defaults. */
  private static Map<String, Object> defaultsof(Object shape) {
    Map<String, Object> out = newmap();
    for (String k : keys(shape)) {
      Object v = get(shape, k);
      if (has(v, "$MERGE")) {
        continue;
      }
      out.put(k, v);
    }
    return out;
  }

  private static Object optsof(Object src, String key) {
    if (null == src) {
      return null;
    }

    // The array form is equivalent to the map form (§9.1).
    List<Object> items = list(src);
    if (null != items) {
      for (Object item : items) {
        if (Refs.canonRef(get(item, "ref")).equals(key)) {
          return get(item, "options");
        }
      }
      return null;
    }

    for (String k : keys(src)) {
      if (!Refs.canonRef(k).equals(key)) {
        continue;
      }
      Object entry = get(src, k);
      return null == map(entry) ? null : get(entry, "options");
    }
    return null;
  }

  /**
   * Merge ONE layer onto the accumulator, honouring the shape's
   * directives. The directive holds at EVERY precedence level, not only
   * between document levels - §9.4 makes it a property of the shape, which
   * does not know which layer a value arrived from.
   */
  private static Object mergeone(Object base, Object over, Object shape) {
    if (null == over) {
      return base;
    }
    Map<String, Object> b = map(base);
    Map<String, Object> o = map(over);
    if (null == b || null == o) {
      return copy(over);
    }

    Map<String, Object> out = newmap();
    out.putAll(b);

    for (String k : keys(o)) {
      Object ov = o.get(k);
      Object directive = get(get(shape, k), "$MERGE");
      Object bv = out.get(k);

      if ("replace".equals(directive)) {
        out.put(k, copy(ov));
      } else if ("append".equals(directive)) {
        List<Object> bl = list(bv);
        List<Object> merged = new ArrayList<>(null == bl ? new ArrayList<>() : bl);
        List<Object> ol = list(ov);
        if (null == ol) {
          merged.add(ov);
        } else {
          merged.addAll(ol);
        }
        out.put(k, merged);
      } else if (has(directive, "deep")) {
        out.put(k, deepto(bv, ov, get(directive, "deep")));
      } else {
        // Library default: deep for maps, REPLACE for lists. struct.merge
        // is element-wise by index, which for option maps is nearly always
        // wrong - ["a"] over ["x","y","z"] yielding ["a","y","z"] is the
        // defect station hit on secrets.providers.
        if (null != map(bv) && null != map(ov)) {
          out.put(k, mergeone(bv, ov, null));
        } else {
          out.put(k, copy(ov));
        }
      }
    }
    return out;
  }

  /** Merge N levels below this key, replace below that. */
  private static Object deepto(Object base, Object over, Object depth) {
    Double n = num(depth);
    if (null == n || n <= 0) {
      return copy(over);
    }
    Map<String, Object> b = map(base);
    Map<String, Object> o = map(over);
    if (null == b || null == o) {
      return copy(over);
    }
    Map<String, Object> out = newmap();
    out.putAll(b);
    for (String k : keys(o)) {
      out.put(k, deepto(out.get(k), o.get(k), n - 1));
    }
    return out;
  }

  /**
   * §9.4: N is an integer of at least 1, and everything else is an error.
   *
   * <p>{@code {"deep": 0}} is rejected DESPITE having an obvious reading,
   * because "replace at this key" already has a spelling and two spellings
   * for one behaviour is the defect class this repo exists to avoid.
   */
  public static void checkShape(Object shape) {
    if (null == map(shape)) {
      return;
    }

    for (String k : keys(shape)) {
      Object v = get(shape, k);
      if (!has(v, "$MERGE")) {
        continue;
      }
      Object directive = get(v, "$MERGE");

      String word = str(directive);
      if (null != word) {
        if (MERGE_WORDS.contains(word)) {
          continue;
        }
        fail(
            "plugin_shape_invalid",
            "invalid $MERGE directive at " + k + ": " + word,
            details("key", k));
      }

      if (has(directive, "deep")) {
        Object n = get(directive, "deep");
        // `asint` is Double-and-integral: `true` is a Boolean and `"2"` a
        // String, so the type test the dynamic ports need is this call.
        Long asint = asint(n);
        if (null != asint && 1 <= asint) {
          continue;
        }
        fail(
            "plugin_shape_invalid",
            "invalid $MERGE deep at " + k + ": " + Json.write(n),
            details("key", k));
      }

      fail(
          "plugin_shape_invalid",
          "invalid $MERGE directive at " + k + ": " + Json.write(directive),
          details("key", k));
    }
  }
}
