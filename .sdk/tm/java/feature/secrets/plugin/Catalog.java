// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Catalog.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.truthy;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * The definition catalog (§10.1).
 *
 * <p>A definition is registered once and may back many instances. Option
 * shapes are validated AT REGISTRATION, not when a document happens to
 * exercise a key - so a malformed shape fails once, and in the same place
 * everywhere (§9.4).
 */
public final class Catalog {

  private final Map<String, Definition> defs = new TreeMap<>();

  public void add(Definition definition) {
    if (null == definition || !Refs.checkName(definition.name)) {
      fail(
          "plugin_definition_name",
          "invalid definition name: " + (null == definition ? "null" : definition.name),
          null);
    }
    // Validate the shape HERE. Deferring it to resolution time means a
    // malformed shape surfaces at a different moment in every host that
    // loads it, which is the divergence the stated domain exists to
    // prevent.
    if (truthy(definition.shape)) {
      Config.checkShape(definition.shape);
    }
    defs.put(definition.name, definition);
  }

  public Definition get(String name) {
    return defs.get(name);
  }

  public boolean has(String name) {
    return defs.containsKey(name);
  }

  public List<String> names() {
    return new ArrayList<>(defs.keySet());
  }

  public static Catalog makeCatalog(List<Definition> definitions) {
    Catalog catalog = new Catalog();
    if (null != definitions) {
      for (Definition d : definitions) {
        catalog.add(d);
      }
    }
    return catalog;
  }
}
