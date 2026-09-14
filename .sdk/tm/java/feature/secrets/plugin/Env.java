// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Env.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.details;
import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.get;
import static JAVAPACKAGE.feature.secrets.plugin.Types.keys;
import static JAVAPACKAGE.feature.secrets.plugin.Types.list;
import static JAVAPACKAGE.feature.secrets.plugin.Types.map;
import static JAVAPACKAGE.feature.secrets.plugin.Types.newmap;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Environment overrides (§9.5) - level 7 of the ladder.
 *
 * <p>One prefix, so nothing drifts: {@code VOXGIG_PLUGIN_*}.
 *
 * <pre>
 *   VOXGIG_PLUGIN_PROFILE            the profile name
 *   VOXGIG_PLUGIN_&lt;REF&gt;_&lt;PATH&gt;       one option
 *   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
 * </pre>
 *
 * <p>THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
 * OTHERWISE. Ref and path are upper-snake with {@code $} -&gt; {@code __}
 * and {@code .} -&gt; {@code _}. But {@code _} is legal in a name and in a
 * tag, and the mapping folds case, so {@code retry$fast} and {@code
 * retry__fast} both encode to {@code RETRY__FAST}.
 *
 * <p>Rather than restrict a grammar the rest of the stack already uses,
 * the host DETECTS THE COLLISION: it encodes every ref it holds, and a key
 * two refs claim is {@code plugin_env_ambiguous}, naming both.
 */
public final class Env {

  private Env() {}

  public static final String ENV_PREFIX = "VOXGIG_PLUGIN_";

  /** {@code retry$fast} -&gt; {@code RETRY__FAST}. */
  public static String encodeRef(String ref) {
    return ref.replace("$", "__").replace(".", "_").toUpperCase(java.util.Locale.ROOT);
  }

  public static Map<String, Object> applyEnv(Object input) {
    Object env = get(input, "env");
    Object reserved = get(input, "reserved");

    List<String> refs = new ArrayList<>();
    List<Object> given = list(get(input, "refs"));
    if (null != given) {
      for (Object r : given) {
        refs.add(Refs.canonRef(r));
      }
    }

    Map<String, Object> out = newmap();
    Map<String, Object> options = newmap();
    out.put("options", options);
    out.put("active", new ArrayList<>());
    out.put("inactive", new ArrayList<>());

    // Encode every ref the host holds, and refuse a key that two of them
    // claim. Done up front so the collision is reported even when no
    // environment variable exercises it - a latent ambiguity is still an
    // ambiguity, and finding it at deploy time is the failure this exists
    // to prevent.
    Map<String, List<String>> byencoded = new TreeMap<>();
    for (String r : refs) {
      byencoded.computeIfAbsent(encodeRef(r), k -> new ArrayList<>()).add(r);
    }
    for (Map.Entry<String, List<String>> e : byencoded.entrySet()) {
      if (e.getValue().size() <= 1) {
        continue;
      }
      List<String> pair = new ArrayList<>(e.getValue());
      pair.sort(null);
      fail(
          "plugin_env_ambiguous",
          "refs collide in the environment encoding as "
              + e.getKey()
              + ": "
              + String.join(", ", pair),
          details("refs", Types.strings(pair)));
    }

    // Longest encoded ref first, so `retry$fast` wins over `retry` on
    // `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
    List<String> encoded = new ArrayList<>(byencoded.keySet());
    encoded.sort((a, b) -> Integer.compare(b.length(), a.length()));

    for (String key : keys(env)) {
      if (!key.startsWith(ENV_PREFIX)) {
        continue;
      }
      String rest = key.substring(ENV_PREFIX.length());

      if ("PROFILE".equals(rest)) {
        out.put("profile", get(env, key));
        continue;
      }

      if ("ACTIVE".equals(rest) || "INACTIVE".equals(rest)) {
        List<Object> target = list(out.get("ACTIVE".equals(rest) ? "active" : "inactive"));
        for (String raw : split(get(env, key))) {
          String ref = Refs.canonRef(raw);
          // The reservation covers EVERY input layer (§9.1).
          // VOXGIG_PLUGIN_INACTIVE=station is easier to set than editing a
          // config file, and INACTIVE has the final word - so guarding
          // documents alone would leave the one lever this mechanism
          // exists to deny wide open.
          checkreserved(ref, reserved);
          target.add(ref);
        }
        continue;
      }

      String enc = null;
      for (String e : encoded) {
        if (rest.equals(e) || rest.startsWith(e + "_")) {
          enc = e;
          break;
        }
      }
      if (null == enc) {
        continue; // not for any ref this host holds
      }

      String ref = byencoded.get(enc).get(0);
      checkreserved(ref, reserved);

      if (rest.equals(enc)) {
        continue; // a ref with no path sets nothing
      }

      String[] path =
          rest.substring(enc.length() + 1).toLowerCase(java.util.Locale.ROOT).split("_", -1);

      if (null == map(options.get(ref))) {
        options.put(ref, newmap());
      }
      Map<String, Object> node = map(options.get(ref));
      for (int i = 0; i < path.length - 1; i++) {
        if (null == map(node.get(path[i]))) {
          node.put(path[i], newmap());
        }
        node = map(node.get(path[i]));
      }
      node.put(path[path.length - 1], parsevalue(get(env, key)));
    }

    return out;
  }

  private static List<String> split(Object value) {
    List<String> out = new ArrayList<>();
    String text = str(value);
    if (null == text) {
      return out;
    }
    for (String part : text.split(",", -1)) {
      String trimmed = part.trim();
      if (!trimmed.isEmpty()) {
        out.add(trimmed);
      }
    }
    return out;
  }

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
   * Values parse as JSON, FALLING BACK TO STRING - so {@code 8080} is a
   * number, {@code true} is a boolean, {@code {"a":1}} is a map, and
   * {@code hello} is the string it looks like rather than a parse error.
   */
  private static Object parsevalue(Object value) {
    String text = str(value);
    if (null == text) {
      return value;
    }
    try {
      return Json.parse(text);
    } catch (RuntimeException e) {
      return value;
    }
  }
}
