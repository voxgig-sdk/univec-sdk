// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Plugin.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import java.util.List;
import java.util.Map;

/**
 * The canonical surface {@code make parity} checks (AGENTS.md §4).
 *
 * <p>Small on purpose (§19): everything else is methods on {@link Host}
 * and {@link Inst}, because a library that grows a second public entry
 * point per feature is a library twenty ports pay for twice.
 *
 * <p>This class FORWARDS rather than implements. The surface is visible in
 * one place, and a name that stops existing stops existing here loudly.
 */
public final class Plugin {

  private Plugin() {}

  public static Host makeHost(Object options) {
    return Host.makeHost(options);
  }

  public static Catalog makeCatalog(List<Definition> definitions) {
    return Catalog.makeCatalog(definitions);
  }

  public static Map<String, Object> parseRef(Object ref) {
    return Refs.parseRef(ref);
  }

  public static String formatRef(Object name, Object tag) {
    return Refs.formatRef(name, tag);
  }

  public static boolean checkName(Object name) {
    return Refs.checkName(name);
  }

  public static boolean checkTag(Object tag) {
    return Refs.checkTag(tag);
  }

  public static String canonRef(Object ref) {
    return Refs.canonRef(ref);
  }

  public static Map<String, Object> normalizeConfig(Object input) {
    return Config.normalizeConfig(input);
  }

  public static Map<String, Object> resolveOptions(Object input) {
    return Config.resolveOptions(input);
  }

  public static List<String> resolveOrder(List<Order.Binding> bindings, Object pin) {
    return Order.resolveOrder(bindings, pin);
  }

  public static List<Object> resolveCandidates(String name, Object sources) {
    return Resolve.resolveCandidates(name, sources);
  }

  public static List<Object> resolveFrom(Object from) {
    return Resolve.resolveFrom(from);
  }

  public static List<Object> resolveCapability(Object req, List<Object> candidates) {
    return Capability.resolveCapability(req, candidates);
  }

  public static Map<String, Object> resolveGraph(Object nodes) {
    return Graph.resolveGraph(nodes);
  }

  public static Map<String, Object> applyEnv(Object input) {
    return Env.applyEnv(input);
  }

  public static Map<String, Object> parseRange(Object range) {
    return Version.parseRange(range);
  }

  public static boolean satisfies(Object version, Object range) {
    return Version.satisfies(version, range);
  }

  public static String codeof(Throwable err) {
    return Types.codeof(err);
  }
}
