// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Resolve.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.get;
import static JAVAPACKAGE.feature.secrets.plugin.Types.list;
import static JAVAPACKAGE.feature.secrets.plugin.Types.newmap;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Dynamic resolution (§10.2) - name to candidate module ids.
 *
 * <p>PURE. It returns the ids a host WOULD try, in order; it does not load
 * anything. That separation is what lets the corpus pin resolution in
 * every language including those with no dynamic loading at all, and it is
 * why §15.4 puts real module loading in per-port integration tests rather
 * than here.
 */
public final class Resolve {

  private Resolve() {}

  public static List<Object> defaultSources() {
    Map<String, Object> src = newmap();
    src.put("kind", "module");
    src.put("prefix", new ArrayList<>(List.of("@voxgig/plugin-", "voxgig-plugin-", "plugin-", "")));
    List<Object> out = new ArrayList<>();
    out.add(src);
    return out;
  }

  public static List<Object> resolveCandidates(String name, Object sources) {
    List<Object> out = new ArrayList<>();

    // A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
    // already a package id; prefixing it produces
    // `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
    if (name.startsWith("@")) {
      out.add(name);
      return out;
    }

    List<Object> given = list(sources);
    List<Object> useit = (null == given || given.isEmpty()) ? defaultSources() : given;

    for (Object src : useit) {
      String kind = str(get(src, "kind"));
      if ("module".equals(kind)) {
        List<Object> prefixes = list(get(src, "prefix"));
        if (null == prefixes || prefixes.isEmpty()) {
          prefixes = new ArrayList<>(List.of(""));
        }
        for (Object p : prefixes) {
          String id = str(p) + name;
          if (!out.contains(id)) {
            out.add(id);
          }
        }
      } else if ("path".equals(kind)) {
        String dir = str(get(src, "dir"));
        dir = null == dir ? "" : dir.replaceAll("/+$", "");
        String id = dir + "/" + name;
        if (!out.contains(id)) {
          out.add(id);
        }
      }
    }

    return out;
  }

  /**
   * A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a name
   * with a letter or {@code @}, so {@code ./local/thing} is not a ref and
   * never reaches candidate generation - seneca allows a path where a
   * plugin name goes, and this design deliberately does not, because a ref
   * is an ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.
   */
  public static List<Object> resolveFrom(Object from) {
    List<Object> out = new ArrayList<>();
    out.add(from);
    return out;
  }
}
