// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Order.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.asint;
import static JAVAPACKAGE.feature.secrets.plugin.Types.details;
import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.get;
import static JAVAPACKAGE.feature.secrets.plugin.Types.keys;
import static JAVAPACKAGE.feature.secrets.plugin.Types.list;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Ordering (§7) - one rule, one place.
 *
 * <p>sdkgen grew two special cases in {@code makeOptions} ({@code test},
 * then {@code station}) and the third was not far off. This sort is the
 * whole replacement, and the tiers are in this order for a reason:
 *
 * <pre>
 *   1 constraints   before/after edges, by ref or by name
 *   2 bands         integer, lower first, default 0
 *   3 declaration   ties break by `pos`
 * </pre>
 *
 * <p>CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both
 * are present. A band expresses a genuine cross-cutting layer; a
 * constraint expresses a relationship between two specific things; and a
 * band chosen by trial and error to fix an ordering bug is a bug wearing a
 * number.
 */
public final class Order {

  private Order() {}

  /** One thing to place: its ref, its position, and its block as authored. */
  public static final class Binding {
    public final String ref;
    public final double pos;
    public final Object order;

    public Binding(String ref, double pos, Object order) {
      this.ref = ref;
      this.pos = pos;
      this.order = order;
    }
  }

  public static List<String> resolveOrder(List<Binding> bindings, Object pin) {
    Map<String, Binding> byref = new LinkedHashMap<>();
    for (Binding b : bindings) {
      byref.put(b.ref, b);
    }

    // Constraints are edges. A constraint naming an ABSENT binding is
    // satisfied VACUOUSLY (§7) - a plugin ordered `after: 'test'` must
    // load in a host with no test plugin. That is sdkgen's __after__
    // behaviour, kept.
    Map<String, List<String>> edges = new TreeMap<>();
    for (Binding b : bindings) {
      edges.put(b.ref, new ArrayList<>());
    }

    for (Binding b : bindings) {
      Object block = b.order;
      // An ABSENT constraint and an EMPTY LIST are both "no constraint".
      if (declared(get(block, "after"))) {
        for (String t : targets(get(block, "after"), bindings)) {
          edges.get(t).add(b.ref);
        }
      }
      if (declared(get(block, "before"))) {
        edges.get(b.ref).addAll(targets(get(block, "before"), bindings));
      }
    }

    // Stable topological sort. Among ready nodes, band first (lower runs
    // first), then `pos` - the position the DOCUMENT visibly states, not
    // the order instances happened to load and not the incarnation `seq`.
    Map<String, Integer> indeg = new TreeMap<>();
    for (Binding b : bindings) {
      indeg.put(b.ref, 0);
    }
    for (List<String> tos : edges.values()) {
      for (String to : tos) {
        indeg.put(to, indeg.get(to) + 1);
      }
    }

    List<String> out = new ArrayList<>();
    List<Binding> ready = new ArrayList<>();
    for (Binding b : bindings) {
      if (0 == indeg.get(b.ref)) {
        ready.add(b);
      }
    }

    while (!ready.isEmpty()) {
      // List.sort is stable, which is what the fall-through to `pos`
      // needs.
      ready.sort(
          (x, y) -> {
            long bx = band(x.order);
            long by = band(y.order);
            if (bx != by) {
              return bx < by ? -1 : 1;
            }
            return Double.compare(x.pos, y.pos);
          });
      Binding next = ready.remove(0);
      out.add(next.ref);
      for (String to : edges.get(next.ref)) {
        indeg.put(to, indeg.get(to) - 1);
        if (0 == indeg.get(to)) {
          ready.add(byref.get(to));
        }
      }
    }

    if (out.size() != bindings.size()) {
      List<String> stuck = new ArrayList<>();
      for (Binding b : bindings) {
        if (!out.contains(b.ref)) {
          stuck.add(b.ref);
        }
      }
      fail(
          "plugin_order_cycle",
          "before/after constraints cycle: " + String.join(" -> ", stuck),
          details("cycle", Types.strings(stuck)));
    }

    return applypin(out, edges, pin);
  }

  /** An integer, and only an integer: {@code true} and {@code "2"} are not bands. */
  public static long band(Object block) {
    Long value = asint(get(block, "band"));
    return null == value ? 0 : value;
  }

  /**
   * Was a constraint stated? An absent value and an EMPTY LIST are both
   * no-constraint - and an empty list is TRUTHY in most languages, which
   * is exactly how this class of bug survives a reading.
   */
  public static boolean declared(Object spec) {
    if (null == spec) {
      return false;
    }
    List<Object> l = list(spec);
    if (null != l) {
      for (Object one : l) {
        if (!"".equals(one)) {
          return true;
        }
      }
      return false;
    }
    return !"".equals(spec);
  }

  /**
   * One spelling or a LIST of them. A list fans out to the UNION of what
   * each names, so after: ['a','b'] means after BOTH, and the same
   * instance named twice - once by name, once by ref - is one edge.
   */
  public static List<String> targets(Object spec, List<Binding> nodes) {
    List<Object> specs = list(spec);
    if (null == specs) {
      specs = new ArrayList<>();
      specs.add(spec);
    }
    List<String> hit = new ArrayList<>();
    for (Object one : specs) {
      String want = str(one);
      if (null == want) {
        continue;
      }
      for (Binding b : nodes) {
        if (hit.contains(b.ref)) {
          continue;
        }
        if (b.ref.equals(want) || Refs.refname(b.ref).equals(want)) {
          hit.add(b.ref);
        }
      }
    }
    return hit;
  }

  /**
   * A PIN IS NOT A CONSTRAINT (§7).
   *
   * <p>Constraints and bands are negotiable by definition - they are what
   * plugins and documents say they want, and the sort's job is to satisfy
   * them all. A pin is the host stating a structural invariant of its own
   * architecture, which is a different kind of claim and must not lose a
   * tie to a document.
   *
   * <p>So a pin PLACES the binding at the named end, and an ordering that
   * would move it away is {@code plugin_order_pinned} - rejected, not
   * honoured into a broken wrap.
   */
  private static List<String> applypin(
      List<String> order, Map<String, List<String>> edges, Object pin) {
    if (null == pin) {
      return order;
    }

    List<String> out = new ArrayList<>(order);

    // SORTED, not insertion order. A pin map is data - it can arrive from
    // a host's own construction options in any order, and two names pinned
    // to the same end are order-sensitive. A TreeMap is sorted by
    // construction, which is why the parser builds one.
    for (String name : keys(pin)) {
      Object want = get(pin, name);
      int idx = -1;
      for (int i = 0; i < out.size(); i++) {
        if (Refs.refname(out.get(i)).equals(name)) {
          idx = i;
          break;
        }
      }
      if (idx < 0) {
        continue;
      }

      // `first`/`outermost` is index 0; `last`/`innermost` is the end.
      // §6.2 makes the first chain binding outermost, which is why the
      // vocabulary is positional and why the two spellings pair this way.
      boolean wantfirst = "first".equals(want) || "outermost".equals(want);
      String ref = out.remove(idx);
      if (wantfirst) {
        out.add(0, ref);
      } else {
        out.add(ref);
      }
    }

    // Now check that the placement did not break a constraint. This is the
    // half that makes a pin a rejection rather than an override: the host
    // wins on position, but it does not get to silently discard a
    // relationship a plugin declared.
    Map<String, Integer> at = new LinkedHashMap<>();
    for (int i = 0; i < out.size(); i++) {
      at.put(out.get(i), i);
    }
    for (Map.Entry<String, List<String>> e : edges.entrySet()) {
      for (String to : e.getValue()) {
        if (at.get(e.getKey()) <= at.get(to)) {
          continue;
        }
        fail(
            "plugin_order_pinned",
            "a pin would move a binding an ordering constrains: "
                + e.getKey()
                + " must precede "
                + to,
            details("before", e.getKey(), "after", to));
      }
    }

    return out;
  }
}
