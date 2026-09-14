// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Capability.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.get;
import static JAVAPACKAGE.feature.secrets.plugin.Types.has;
import static JAVAPACKAGE.feature.secrets.plugin.Types.keys;
import static JAVAPACKAGE.feature.secrets.plugin.Types.list;
import static JAVAPACKAGE.feature.secrets.plugin.Types.map;
import static JAVAPACKAGE.feature.secrets.plugin.Types.num;
import static JAVAPACKAGE.feature.secrets.plugin.Types.same;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;

import java.util.ArrayList;
import java.util.List;

/**
 * Capabilities (§11.1).
 *
 * <p>A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a
 * dependency on something that can do the job, and which instance is doing
 * it is exactly the configuration detail a plugin must not care about.
 *
 * <p>But A BINDING IS TO AN INSTANCE, not to a capability, which is what
 * decides behaviour when the bound provider leaves while another match
 * remains.
 */
public final class Capability {

  private Capability() {}

  /**
   * Rank the matching live providers and return them best-first: highest
   * {@code version}, then LOWEST {@code priority} (default 0), then
   * declaration position {@code pos} ascending.
   *
   * <p>{@code priority} is a field on the capability rather than §7's
   * {@code order} band, because bands live on POINT BINDINGS: a provider
   * may have several bindings with different bands, or none at all, so a
   * rank reaching for one would be undefined in the common case.
   *
   * <p>Without a total rank, "any provider satisfies" is true of the GRAPH
   * and useless to the PLUGIN - two ports could bind different {@code
   * store} instances, both resolve green, and behave differently, which is
   * precisely the divergence a shared corpus exists to catch.
   */
  public static List<Object> resolveCapability(Object req, List<Object> candidates) {
    List<Object> hits = new ArrayList<>();
    for (Object c : candidates) {
      if (matches(req, get(c, "provides"))) {
        hits.add(c);
      }
    }
    // STABLE: List.sort is a merge sort, and the rank falls through to
    // `pos`.
    hits.sort((a, b) -> compareRank(a, b));
    return hits;
  }

  private static int compareRank(Object a, Object b) {
    Object pa = get(a, "provides");
    Object pb = get(b, "provides");
    String va = str(get(pa, "version"));
    String vb = str(get(pb, "version"));

    // An ABSENT version sorts LAST, whatever the other is - "no version"
    // loses to every version rather than being read as 0.0.0.
    int absent = Boolean.compare(null == va, null == vb);
    if (0 != absent) {
      return absent;
    }
    if (null != va) {
      List<Long> la = Version.versionParts(va);
      List<Long> lb = Version.versionParts(vb);
      for (int i = 0; i < Math.max(la.size(), lb.size()); i++) {
        long x = i < la.size() ? la.get(i) : 0;
        long y = i < lb.size() ? lb.get(i) : 0;
        if (x != y) {
          return x < y ? 1 : -1; // higher version first
        }
      }
    }

    double qa = null == num(get(pa, "priority")) ? 0 : num(get(pa, "priority"));
    double qb = null == num(get(pb, "priority")) ? 0 : num(get(pb, "priority"));
    if (qa != qb) {
      return qa < qb ? -1 : 1;
    }

    double sa = null == num(get(a, "pos")) ? 0 : num(get(a, "pos"));
    double sb = null == num(get(b, "pos")) ? 0 : num(get(b, "pos"));
    return Double.compare(sa, sb);
  }

  public static boolean matches(Object req, Object prov) {
    if (!same(get(req, "name"), get(prov, "name"))) {
      return false;
    }

    Object range = get(req, "range");
    if (null != range) {
      Object version = get(prov, "version");
      if (null == version) {
        return false;
      }
      if (!Version.satisfiesq(version, range)) {
        return false;
      }
    }

    // `match` is checked against the provider's `attrs`, key by key. A key
    // the provider does not carry is a miss, not a pass: a requirement
    // asking for `transactional: true` must not be satisfied by a provider
    // that never said.
    Object want = get(req, "match");
    if (null != want) {
      Object attrs = get(prov, "attrs");
      for (String key : keys(want)) {
        if (!has(attrs, key)) {
          return false;
        }
        if (!matchvalue(get(want, key), get(attrs, key))) {
          return false;
        }
      }
    }

    return true;
  }

  /**
   * PARTIAL MATCH, RECURSING INTO MAPS (§11.1).
   *
   * <p>§11.1 defines {@code match} as "a partial match against {@code
   * attrs}, with exactly the semantics voxgig/struct and the omni corpus
   * already define for {@code match} - every leaf in the requirement must
   * be present and equal in the capability, keys not mentioned are not
   * checked."
   *
   * <p>Equality is by JSON TYPE as well as value: {@code transactional: 1}
   * does not satisfy {@code transactional: true}. JAVA NEEDS NO GUARD FOR
   * THAT - {@code Boolean.equals(Double)} is false, with no coercion
   * between them - so the explicit boolean check php, perl and lua each
   * carry would be dead code here.
   *
   * <p>A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
   */
  public static boolean matchvalue(Object want, Object got) {
    if (null != map(want)) {
      if (null == map(got)) {
        return false;
      }
      for (String key : keys(want)) {
        if (!has(got, key)) {
          return false;
        }
        if (!matchvalue(get(want, key), get(got, key))) {
          return false;
        }
      }
      return true;
    }

    List<Object> wl = list(want);
    if (null != wl) {
      List<Object> gl = list(got);
      if (null == gl || wl.size() != gl.size()) {
        return false;
      }
      for (int i = 0; i < wl.size(); i++) {
        if (!matchvalue(wl.get(i), gl.get(i))) {
          return false;
        }
      }
      return true;
    }

    return same(want, got);
  }
}
