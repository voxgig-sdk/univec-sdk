// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Graph.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.get;
import static JAVAPACKAGE.feature.secrets.plugin.Types.has;
import static JAVAPACKAGE.feature.secrets.plugin.Types.keys;
import static JAVAPACKAGE.feature.secrets.plugin.Types.list;
import static JAVAPACKAGE.feature.secrets.plugin.Types.newmap;
import static JAVAPACKAGE.feature.secrets.plugin.Types.num;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;
import static JAVAPACKAGE.feature.secrets.plugin.Types.truthy;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

/**
 * Whole-graph resolution (§11.4) - a phase, not a discovery.
 *
 * <p>"Activate, and wait in {@code pending} if you must" is correct and,
 * on its own, produces a terrible experience: apply twenty instances
 * against a registry missing one thing and you get NINETEEN pending rows
 * and no statement of what is actually wrong.
 *
 * <p>{@code resolveGraph} is a PURE FUNCTION of the registry and the
 * intended activation set. No callbacks run, no state changes, nothing is
 * touched. It answers for the whole graph at once which instances can be
 * live, and for each blocked one THE SPECIFIC REQUIREMENT that is unmet,
 * and why.
 *
 * <p>The failure mode being designed against is a famous one: OSGi's
 * resolver is correct and its diagnostics are legendarily unusable. A
 * resolver that says "blocked" without saying WHY has moved the problem
 * rather than solved it, so {@code why} is part of the contract and the
 * corpus pins its shape.
 */
public final class Graph {

  private Graph() {}

  public static Map<String, Object> resolveGraph(Object nodes) {
    List<Object> all = list(nodes);
    all = null == all ? new ArrayList<>() : all;

    Map<String, Object> byref = new TreeMap<>();
    for (Object n : all) {
      byref.put(str(get(n, "ref")), n);
    }

    Set<String> resolved = new LinkedHashSet<>();
    Map<String, Object> blocked = new TreeMap<>();

    // Fixed point: a node resolves when every mandatory requirement is met
    // by an ALREADY-RESOLVED provider. Iterating to a fixed point is what
    // makes a provider that is itself blocked propagate, rather than each
    // node being judged against the raw registry.
    boolean moved = true;
    while (moved) {
      moved = false;
      for (Object n : all) {
        String ref = str(get(n, "ref"));
        if (resolved.contains(ref)) {
          continue;
        }
        if (null != firstunmet(n, byref, resolved)) {
          continue;
        }
        resolved.add(ref);
        moved = true;
      }
    }

    for (Object n : all) {
      String ref = str(get(n, "ref"));
      if (resolved.contains(ref)) {
        continue;
      }
      Object why = firstunmet(n, byref, resolved);
      if (null != why) {
        blocked.put(ref, why);
      }
    }

    List<String> sorted = new ArrayList<>(resolved);
    sorted.sort(null);

    Map<String, Object> out = newmap();
    out.put("resolved", Types.strings(sorted));
    out.put("blocked", new ArrayList<>(blocked.values()));
    return out;
  }

  /**
   * The FIRST unmet requirement, with the most specific explanation
   * available. Order matters: "no provider at all" and "a provider at the
   * wrong version" are different problems and a reader must not have to
   * guess which they have.
   */
  private static Object firstunmet(Object node, Map<String, Object> byref, Set<String> resolved) {
    List<Object> requires = list(get(node, "requires"));
    requires = null == requires ? new ArrayList<>() : requires;

    for (Object req : requires) {
      if (truthy(get(req, "optional"))) {
        continue;
      }
      Object name = get(req, "name");
      List<Object> all = candidates(byref, name);
      if (all.isEmpty()) {
        return unmet(node, name, why("absent"));
      }

      List<Object> ok = Capability.resolveCapability(req, all);
      if (!ok.isEmpty()) {
        // A provider exists and matches - but if none of them is itself
        // resolved, this node is blocked BEHIND it, and the chain is the
        // useful answer rather than "unmet".
        boolean any = false;
        for (Object c : ok) {
          if (resolved.contains(str(get(c, "ref")))) {
            any = true;
            break;
          }
        }
        if (any) {
          continue;
        }
        List<String> chain = new ArrayList<>();
        for (Object c : ok) {
          chain.add(str(get(c, "ref")));
        }
        chain.sort(null);
        Map<String, Object> w = newmap();
        w.put("kind", "blocked");
        w.put("chain", Types.strings(chain));
        return unmet(node, name, w);
      }

      // Providers exist and none matched. Say which test failed.
      Object range = get(req, "range");
      if (null != range) {
        List<String> versions = new ArrayList<>();
        for (Object c : all) {
          Object have = get(get(c, "provides"), "version");
          if (null == have || !Version.satisfiesq(have, range)) {
            versions.add(null == have ? "(none)" : str(have));
          }
        }
        if (!versions.isEmpty()) {
          versions.sort(null);
          Map<String, Object> w = newmap();
          w.put("kind", "version");
          w.put("range", range);
          w.put("found", Types.strings(versions));
          return unmet(node, name, w);
        }
      }

      Object want = get(req, "match");
      if (null != want) {
        for (Object c : all) {
          Object attrs = get(get(c, "provides"), "attrs");
          for (String k : keys(want)) {
            if (has(attrs, k) && Capability.matchvalue(get(want, k), get(attrs, k))) {
              continue;
            }
            Map<String, Object> w = newmap();
            w.put("kind", "match");
            w.put("failing", k);
            w.put("want", get(want, k));
            w.put("found", get(attrs, k));
            return unmet(node, name, w);
          }
        }
      }

      return unmet(node, name, why("absent"));
    }
    return null;
  }

  private static Map<String, Object> why(String kind) {
    Map<String, Object> out = newmap();
    out.put("kind", kind);
    return out;
  }

  private static Map<String, Object> unmet(Object node, Object name, Object why) {
    Map<String, Object> out = newmap();
    out.put("ref", get(node, "ref"));
    out.put("unmet", name);
    out.put("why", why);
    return out;
  }

  private static List<Object> candidates(Map<String, Object> byref, Object name) {
    List<Object> out = new ArrayList<>();
    // A NODE SATISFIES ITS OWN REF (section 11.1), and the graph learned
    // it here. Considering only declared capabilities made `resolve`
    // answer `absent` about a provider sitting right there and live -
    // section 11.4's job is explaining the graph the runtime reconciles,
    // and it was explaining a different one.
    String nm = str(name);
    String asref = Refs.canon(null == nm ? "" : nm);
    // The map is sorted, so the walk is - which is the whole reason it is
    // a TreeMap.
    for (Object node : byref.values()) {
      // The ref match WINS OUTRIGHT for that node, as at runtime: one
      // candidate, not two, for a node both named `b` and providing `b`.
      if (asref.equals(str(get(node, "ref")))) {
        Map<String, Object> refcand = newmap();
        refcand.put("ref", get(node, "ref"));
        Double refpos = num(get(node, "pos"));
        refcand.put("pos", null == refpos ? 0.0 : refpos);
        Map<String, Object> prov = newmap();
        prov.put("name", name);
        refcand.put("provides", prov);
        out.add(refcand);
        continue;
      }
      List<Object> provides = list(get(node, "provides"));
      if (null == provides) {
        continue;
      }
      for (Object prov : provides) {
        if (!Types.same(get(prov, "name"), name)) {
          continue;
        }
        Map<String, Object> cand = newmap();
        cand.put("ref", get(node, "ref"));
        Double pos = num(get(node, "pos"));
        cand.put("pos", null == pos ? 0.0 : pos);
        cand.put("provides", prov);
        out.add(cand);
      }
    }
    return out;
  }
}
