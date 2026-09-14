// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Depend.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.details;
import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.get;
import static JAVAPACKAGE.feature.secrets.plugin.Types.list;
import static JAVAPACKAGE.feature.secrets.plugin.Types.map;
import static JAVAPACKAGE.feature.secrets.plugin.Types.newmap;
import static JAVAPACKAGE.feature.secrets.plugin.Types.same;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;
import static JAVAPACKAGE.feature.secrets.plugin.Types.truthy;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;

/**
 * Dependency cardinality, policy, and the restart graph (§11.3).
 *
 * <p>TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
 * because only it knows what it can cope with:
 *
 * <pre>
 *                | static (default)          | dynamic
 *   -------------|---------------------------|--------------------------
 *   mandatory    | unmet -&gt; pending;         | unmet -&gt; pending;
 *   (default)    | lost  -&gt; pending,         | lost  -&gt; STAYS LIVE,
 *                |          recursively      |          notified
 *   -------------|---------------------------|--------------------------
 *   optional:true| never gates activation;   | never gates activation;
 *                | a change deactivates and  | a change is a
 *                | reactivates               | notification, nothing else
 * </pre>
 *
 * <p>{@code dynamic} means the plugin has said, IN WRITING, that it can
 * survive its provider being swapped underneath it. It is not the default
 * because most plugins cannot, and the cost of wrongly assuming they can
 * is a live instance holding a dead reference.
 *
 * <p>The rebinding-preference axis is deliberately omitted. OSGi has
 * reluctant vs greedy and it is a knob every author must understand to
 * read anyone else's component; we take always-reluctant. Three axes were
 * more than the model can carry across twenty ports.
 */
public final class Depend {

  private Depend() {}

  /** A node of the requirement graph, as plain data for the detector. */
  public static final class Node {
    public final String ref;
    public final List<String> provides;
    public final List<Object> requires;

    public Node(String ref, List<String> provides, List<Object> requires) {
      this.ref = ref;
      this.provides = provides;
      this.requires = requires;
    }
  }

  /** A bare string is shorthand for {@code {name}}. */
  public static Map<String, Object> normrequire(Object raw) {
    Map<String, Object> out = newmap();
    if (raw instanceof String) {
      out.put("name", raw);
      return out;
    }
    Map<String, Object> m = map(raw);
    if (null != m) {
      out.putAll(m);
    }
    return out;
  }

  /**
   * The requirements a definition declared, normalized.
   *
   * <p>BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
   *
   * <p>The instance-level {@code policy} and {@code optional} list are how
   * a DOCUMENT states the axis without editing the definition, and they
   * apply to every requirement. The per-requirement form is the one
   * §11.1's object syntax exists for, and it is strictly more expressive:
   * an instance that is {@code static} on its store and {@code dynamic} on
   * its metrics cannot be written at all at the instance level.
   *
   * <p>{@code optional} unions rather than overriding - both spellings are
   * statements that this requirement need not gate activation, and there
   * is no reading under which one of them means "actually, mandatory".
   */
  public static List<Object> requirements(Object options) {
    List<Object> raw = list(get(options, "requires"));
    raw = null == raw ? new ArrayList<>() : raw;
    List<Object> marked = list(get(options, "optional"));
    Object fallback = get(options, "policy");

    List<Object> out = new ArrayList<>();
    for (Object item : raw) {
      Map<String, Object> req = normrequire(item);
      boolean ismarked = false;
      if (null != marked) {
        for (Object m : marked) {
          if (same(m, req.get("name"))) {
            ismarked = true;
            break;
          }
        }
      }
      if (truthy(req.get("optional")) || ismarked) {
        req.put("optional", Boolean.TRUE);
      }
      if (null == req.get("policy") && null != fallback) {
        req.put("policy", fallback);
      }
      out.add(req);
    }
    return out;
  }

  /**
   * Does losing this requirement's SELECTED provider restart the consumer?
   * The mandatory ones under {@code static}, and the {@code static}
   * optional ones - both make a capability change deactivate and
   * reactivate. {@code dynamic} never restarts.
   */
  public static boolean restartsonloss(Object req) {
    String policy = str(get(req, "policy"));
    return !"dynamic".equals(null == policy ? "static" : policy);
  }

  /**
   * Does an unmet requirement keep the consumer out of {@code live}?
   *
   * <p>Cardinality alone decides this, NOT policy. {@code dynamic} is a
   * statement about surviving a SWAP, not about starting without the thing
   * at all - a mandatory-dynamic consumer still waits in {@code pending}
   * for its first provider.
   */
  public static boolean gatesactivation(Object req) {
    return !Boolean.TRUE.equals(get(req, "optional"));
  }

  /**
   * Edges that can cause a restart, which is exactly the set a cycle must
   * be detected over (§11.3).
   *
   * <p>ONLY {@code dynamic} OPTIONAL EDGES ARE EXCLUDED, and they are the
   * ones the exclusion was for: two plugins that optionally and
   * dynamically consume each other's capabilities both activate happily,
   * neither gates on the other, and each is merely notified when the other
   * appears. Nothing restarts, so nothing oscillates.
   *
   * <p>An earlier draft of §11.3 excluded EVERY optional edge and thereby
   * admitted the non-terminating case it was trying to permit.
   */
  public static boolean restartcausing(Object req) {
    return gatesactivation(req) || restartsonloss(req);
  }

  /**
   * A cycle through restart-causing requirements is {@code
   * plugin_dependency_cycle}, detected AT LOAD - before anything runs,
   * because the failure it describes is a non-terminating reconcile and
   * the only safe time to report that is before it starts.
   *
   * <p>The graph is over capabilities, not refs: an edge runs from a
   * consumer to EVERY node that provides what it needs, because any of
   * them could be the one selected and a cycle through any is a cycle. A
   * node also satisfies its own name as a ref (§11.1), which is why the
   * ref is a provider of itself here.
   */
  public static List<String> dependencycycle(List<Node> nodes) {
    // TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
    // matched differently - a capability by its exact name, a ref through
    // the canonical spelling (section 4 rule 5) - and one map keyed by
    // both can only do one of them. Keyed by both and looked up raw, as
    // this was, a cycle spelled `a$`/`b$` found no providers and EVADED
    // the load-time check that exists to catch a non-terminating
    // reconcile.
    Map<String, List<String>> bycap = new TreeMap<>();
    Set<String> isref = new TreeSet<>();
    for (Node n : nodes) {
      isref.add(n.ref);
      for (String cap : n.provides) {
        bycap.computeIfAbsent(cap, k -> new ArrayList<>()).add(n.ref);
      }
    }

    Map<String, List<String>> edges = new TreeMap<>();
    for (Node n : nodes) {
      List<String> out = new ArrayList<>();
      for (Object req : n.requires) {
        if (!restartcausing(req)) {
          continue;
        }
        String reqname = str(get(req, "name"));
        List<String> from = new ArrayList<>();
        List<String> list = bycap.get(reqname);
        if (null != list) {
          from.addAll(list);
        }
        // A node satisfies its own name AS A REF (section 11.1),
        // canonically - exactly what `providersof` does at runtime.
        // `canon` hands back a name no ref could have unchanged, and no
        // instance ref can equal one, so it is the tolerant test.
        String asref = Refs.canon(null == reqname ? "" : reqname);
        if (isref.contains(asref) && !from.contains(asref)) {
          from.add(asref);
        }
        for (String p : from) {
          if (!p.equals(n.ref) && !out.contains(p)) {
            out.add(p);
          }
        }
      }
      out.sort(null);
      edges.put(n.ref, out);
    }

    // Iterative DFS with an explicit stack: twenty ports, and several of
    // them have no recursion budget worth relying on.
    final int white = 0;
    final int grey = 1;
    final int black = 2;
    Map<String, Integer> colour = new TreeMap<>();
    for (Node n : nodes) {
      colour.put(n.ref, white);
    }

    for (String start : new ArrayList<>(edges.keySet())) {
      if (white != colour.get(start)) {
        continue;
      }

      List<String> path = new ArrayList<>();
      path.add(start);
      List<Object[]> stack = new ArrayList<>();
      stack.add(new Object[] {start, 0});
      colour.put(start, grey);

      while (!stack.isEmpty()) {
        Object[] top = stack.get(stack.size() - 1);
        String node = (String) top[0];
        int index = (Integer) top[1];
        List<String> outs = edges.get(node);
        if (outs.size() <= index) {
          colour.put(node, black);
          stack.remove(stack.size() - 1);
          path.remove(path.size() - 1);
          continue;
        }
        String next = outs.get(index);
        top[1] = index + 1;
        if (grey == colour.get(next)) {
          // Report the cycle itself, not the walk that found it.
          List<String> cycle = new ArrayList<>(path.subList(path.indexOf(next), path.size()));
          cycle.add(next);
          return cycle;
        }
        if (black == colour.get(next)) {
          continue;
        }
        colour.put(next, grey);
        path.add(next);
        stack.add(new Object[] {next, 0});
      }
    }
    return null;
  }

  /**
   * Raise on a cycle, naming it. Separate from the detector so the
   * detector stays pure and corpus-testable.
   */
  public static void checkcycle(List<Node> nodes) {
    List<String> cycle = dependencycycle(nodes);
    if (null == cycle) {
      return;
    }
    fail(
        "plugin_dependency_cycle",
        "requirements cycle: " + String.join(" -> ", cycle),
        details("cycle", Types.strings(cycle)));
  }
}
