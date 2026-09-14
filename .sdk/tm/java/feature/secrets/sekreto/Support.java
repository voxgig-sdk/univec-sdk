// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/src/com/voxgig/sekreto/Support.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// How a provider kind becomes a voxgig/plugin definition, and the few
// helpers both halves of the split need.
//
// This is the whole bridge between the two libraries. A definition's
// `name` is the `kind` a spec names; its `define` reads the spec as
// `inst.options()`, builds the provider, and exports it under
// PROVIDER_EXPORT. Every built-in and every plugin is made this way, so
// a custom provider kind is one call.
//
// A port of typescript/src/provider/support.ts, which is canonical.

package JAVAPACKAGE.feature.secrets.sekreto;

import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import java.util.Map;
import java.util.TreeMap;
import JAVAPACKAGE.feature.secrets.plugin.Definition;
import JAVAPACKAGE.feature.secrets.plugin.PluginException;

public final class Support {

  private Support() {}

  /**
   * The export key under which a provider definition publishes the
   * provider it built. `Sekreto` reads `<ref>/provider` off the host.
   */
  public static final String PROVIDER_EXPORT = "provider";

  /**
   * The voxgig/plugin error code a SekretoError travels under when it is
   * raised inside a definition's `define`.
   *
   * <p>plugin wraps a code-less error raised by a callback as
   * `plugin_define_failed`, and keeps one that already carries a code. A
   * provider that refuses its own configuration - `kv: 3`, a missing
   * project - raises a SekretoError, and the spec pins that message byte
   * for byte, so it must come back out of the host exactly as it went in.
   * `providerplugin` gives it this code on the way in; `Sekreto` turns it
   * back into a SekretoError on the way out. Nowhere else catches and
   * rewraps.
   */
  public static final String ERROR_CODE = "sekreto_error";

  /** Builds one provider from its declarative spec. */
  public interface Make {
    Provider make(Map<String, Object> spec);
  }

  /**
   * A provider kind, as a voxgig/plugin definition.
   *
   * <p>Nothing runs at `activate`: a provider opens nothing until its
   * first lookup, so there is nothing to capture - one that does hold a
   * resource acquires it there and lets the instance scope unwind it.
   *
   * <pre>
   *   Definition mystore = Support.providerplugin(
   *       "mystore", spec -&gt; new MyStore(Support.text(spec.get("addr"))));
   * </pre>
   */
  public static Definition providerplugin(String kind, Make make) {
    Definition definition = new Definition(kind);

    definition.define = inst -> {
      Map<String, Object> spec = map(inst.options());
      Provider provider;
      try {
        provider = make.make(null == spec ? new TreeMap<>() : spec);
      } catch (SekretoError err) {
        Map<String, Object> details = new TreeMap<>();
        details.put("ref", inst.ref);
        details.put("cause", err.getMessage());
        throw new PluginException(ERROR_CODE, err.getMessage(), details);
      }
      inst.export(PROVIDER_EXPORT, provider);
    };

    return definition;
  }

  /** A spec field as text, or null when it is not there. */
  public static String text(Object value) {
    return null == value ? null : String.valueOf(value);
  }

  /** A spec field as text, or the fallback when it is not there. */
  public static String textor(Object value, String fallback) {
    return null == value ? fallback : String.valueOf(value);
  }

  /** A spec field as a map, or null when it is not one. */
  @SuppressWarnings("unchecked")
  public static Map<String, Object> map(Object value) {
    return value instanceof Map ? (Map<String, Object>) value : null;
  }
}
