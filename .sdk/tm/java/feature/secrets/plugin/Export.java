// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Export.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.details;
import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;

import java.util.ArrayList;
import java.util.List;

/**
 * Exports (§11).
 *
 * <p>An instance publishes values for other plugins and for the
 * application. Read with {@code host.exports("retry$fast/client")}.
 *
 * <p>THE UNQUALIFIED ALIAS IS THE INTERESTING PART. {@code retry/client}
 * resolves to the UNTAGGED instance if one exists; if not, and exactly one
 * tagged instance exports that key, it resolves to that one; if two do, it
 * is {@code plugin_export_ambiguous} - deliberately diverging from
 * seneca's silent last-wins, because with multi-instance as a headline
 * feature an ambiguous alias is a defect waiting for production.
 */
public final class Export {

  private Export() {}

  /** One published value: which instance, under which key. */
  public static final class Exported {
    public final String ref;
    public final String key;
    public final Object value;

    public Exported(String ref, String key, Object value) {
      this.ref = ref;
      this.key = key;
      this.value = value;
    }
  }

  public static Object resolveExport(String spec, List<Exported> exported) {
    int cut = spec.indexOf('/');
    if (cut < 0) {
      fail("plugin_export_ambiguous", "export spec needs a key: " + spec, details("spec", spec));
    }
    String head = spec.substring(0, cut);
    String key = spec.substring(cut + 1);

    // A fully qualified ref: exactly one answer or none.
    String want = Refs.canon(head);
    for (Exported e : exported) {
      if (e.ref.equals(want) && e.key.equals(key)) {
        return e.value;
      }
    }

    // An alias: the name, not a ref. Look at every instance of it.
    List<Exported> byname = new ArrayList<>();
    for (Exported e : exported) {
      if (Refs.refname(e.ref).equals(head) && e.key.equals(key)) {
        byname.add(e);
      }
    }
    if (byname.isEmpty()) {
      return null;
    }

    for (Exported e : byname) {
      if (str(Refs.parseRef(e.ref).get("tag")).isEmpty()) {
        return e.value;
      }
    }

    if (1 == byname.size()) {
      return byname.get(0).value;
    }

    List<String> refs = new ArrayList<>();
    for (Exported e : byname) {
      refs.add(e.ref);
    }
    refs.sort(null);
    fail(
        "plugin_export_ambiguous",
        "alias " + spec + " matches " + refs.size() + " instances: " + String.join(", ", refs),
        // `spec` is not one of §12's fields, so it does not render - the
        // same detail map every other port builds, and the same message.
        details("spec", spec, "refs", Types.strings(refs)));
    return null;
  }
}
