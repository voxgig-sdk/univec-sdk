// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Point.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.details;
import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.get;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;
import static JAVAPACKAGE.feature.secrets.plugin.Types.truthy;

import java.util.ArrayList;
import java.util.List;

/**
 * Extension points (§6). Three kinds, chosen because they are what the two
 * existing systems actually needed, and no more.
 *
 * <p>A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
 * deactivation possible: sdkgen's {@code utility.fetcher = wrapped} is not
 * undoable, but "this instance holds slot 3 of the request chain" is
 * undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
 * paper called <i>Listeners Considered Harmful</i>, and for exactly this
 * reason.
 */
public final class Point {

  private Point() {}

  /** The next link of a chain (§6.2), or the base at the end of it. */
  public interface NextFn {
    Object call(Object[] args);
  }

  /**
   * EVERY binding has one signature, whatever kind of point it is on: a
   * hook and a provider ignore the {@code next} they are handed, a chain
   * uses it. One signature is what lets {@code bound} return a single list
   * the three callers share, rather than three parallel registries that
   * can disagree about which instance holds slot 3.
   */
  public interface BindFn {
    Object call(NextFn next, Object[] args);
  }

  public static final class Bound {
    public final String ref;
    public final String point;
    public final BindFn func;
    public long band;

    public Bound(String ref, String point, BindFn func, long band) {
      this.ref = ref;
      this.point = point;
      this.func = func;
      this.band = band;
    }

    public Bound withBand(long band) {
      return new Bound(this.ref, this.point, this.func, band);
    }
  }

  /**
   * §6.1: "fan-out" is not one answer but four. In a language with
   * asynchrony, "call every binding" hides a decision - start them all and
   * wait, await each in turn, or do not wait - and a design that leaves it
   * unsaid gets four different answers from four ports, in the concurrency
   * behaviour of production code no corpus entry happens to cover.
   */
  public static final List<String> MODES = List.of("emit", "parallel", "serial", "bail");

  /** Fan-out. Return values are ignored except in {@code bail}. */
  public static Object emit(List<Bound> bindings, String mode, Object arg) {
    if ("bail".equals(mode)) {
      // Stops at the first binding that RETURNS A VALUE - the "handled,
      // stop" case. A `null` RETURN DECLINES (§6.1): java has one way to
      // say nothing, and the model's rule is written to that rather than
      // to JavaScript's null/undefined pair. Not truthiness - `false`, `0`
      // and `""` are values.
      for (Bound b : bindings) {
        Object v = b.func.call(null, new Object[] {arg});
        if (null != v) {
          return v;
        }
      }
      return null;
    }

    List<Object> errors = new ArrayList<>();
    for (Bound b : bindings) {
      try {
        b.func.call(null, new Object[] {arg});
      } catch (RuntimeException e) {
        // `emit` raises synchronously; the collecting modes gather.
        if ("emit".equals(mode)) {
          throw e;
        }
        errors.add(e.getMessage());
      }
    }
    return "emit".equals(mode) ? null : errors;
  }

  /**
   * Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2).
   *
   * <p>Recomputed by the host whenever the live set changes, and cached
   * between changes. Plugins receive {@code next} as an argument; they
   * never see or store the previous value of anything. A plugin that
   * stashes {@code next} and calls it after deactivation is a bug the host
   * cannot prevent, and this says so rather than pretending otherwise.
   */
  public static NextFn compose(List<Bound> bindings, NextFn base) {
    NextFn next = base;
    for (int i = bindings.size() - 1; 0 <= i; i--) {
      final BindFn func = bindings.get(i).func;
      final NextFn inner = next;
      // `final` locals per iteration, so each layer closes over its own
      // pair - java gives that for free where ruby's blocks do not.
      next = args -> func.call(inner, args);
    }
    return next;
  }

  /**
   * At most one live implementation (§6.3). The winner is the highest
   * band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
   * silently ignored.
   */
  public static final class Picked {
    public final Bound winner;
    public final List<String> shadowed;

    Picked(Bound winner, List<String> shadowed) {
      this.winner = winner;
      this.shadowed = shadowed;
    }
  }

  public static Picked provider(List<Bound> bindings, Object spec) {
    if (bindings.isEmpty()) {
      return new Picked(null, new ArrayList<>());
    }

    if (truthy(get(spec, "exclusive")) && 1 < bindings.size()) {
      List<String> refs = new ArrayList<>();
      for (Bound b : bindings) {
        refs.add(b.ref);
      }
      refs.sort(null);
      fail(
          "plugin_point_exclusive",
          "point is exclusive and has " + bindings.size() + " bindings: " + String.join(", ", refs),
          details("refs", Types.strings(refs)));
    }

    List<Bound> ranked = new ArrayList<>(bindings);
    ranked.sort(
        (a, b) -> {
          if (a.band != b.band) {
            return a.band < b.band ? 1 : -1; // higher band first
          }
          return a.ref.compareTo(b.ref);
        });
    List<String> shadowed = new ArrayList<>();
    for (int i = 1; i < ranked.size(); i++) {
      shadowed.add(ranked.get(i).ref);
    }
    return new Picked(ranked.get(0), shadowed);
  }
}
