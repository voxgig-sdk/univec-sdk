// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/point.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Extension points (section 6). Three kinds, chosen because they are what
/// the two existing systems actually needed, and no more.
///
/// A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
/// deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
/// undoable, but "this instance holds slot 3 of the request chain" is
/// undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
/// paper called *Listeners Considered Harmful*, and for exactly this reason.
library;

import 'types.dart' as t;

/// EVERY BINDING IS ARITY TWO, `(next, arg)`, hook and chain alike. `next`
/// is null for a hook. One signature means this file does not have to know
/// which kind of point it is holding - and the kind is the HOST's property,
/// not the binding's.
typedef BindingFn = dynamic Function(dynamic next, dynamic arg);

/// A live binding. An internal shape, never a corpus value.
class Binding {
  final String ref;
  final String point;
  final BindingFn fn;
  int band;
  Binding(this.ref, this.point, this.fn, this.band);
  Binding withBand(int b) => Binding(ref, point, fn, b);
}

/// Section 6.1: "fan-out" is not one answer but four. In a language with
/// asynchrony, "call every binding" hides a decision - start them all and
/// wait, await each in turn, or do not wait - and a design that leaves it
/// unsaid gets four different answers from four ports, in the concurrency
/// behaviour of production code no corpus entry happens to cover.
///
/// DART IS A PORT WHERE THAT IS LOUD: `Future.wait` is right there, and
/// making `emit` return one would turn every hook point into a scheduling
/// decision and every ordering assertion into a race. The host stays
/// synchronous (section 5.2) and the modes stay data.
const modes = ['emit', 'parallel', 'serial', 'bail'];

/// Fan-out. Return values are ignored except in `bail`.
dynamic pointEmit(List<Binding> bindings, String mode, dynamic arg) {
  if (mode == 'bail') {
    // Stops at the first binding that RETURNS A VALUE - the "handled, stop"
    // case. A `null` RETURN DECLINES (section 6.1): dart has one way to say
    // nothing, and the model's rule is written to that rather than to
    // JavaScript's null/undefined pair. `!= null`, NOT truthiness - `false`
    // is a value.
    for (final b in bindings) {
      final v = b.fn(null, arg);
      if (v != null) return v;
    }
    return null;
  }

  final errors = <String>[];
  for (final b in bindings) {
    try {
      b.fn(null, arg);
    } catch (e) {
      // `emit` raises synchronously; the collecting modes gather.
      if (mode == 'emit') rethrow;
      errors.add(t.messageOf(e));
    }
  }
  return mode == 'emit' ? null : errors;
}

/// Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (section 6.2).
///
/// Recomputed by the host whenever the live set changes, and cached between
/// changes. Plugins receive `next` as an argument; they never see or store
/// the previous value of anything. A plugin that stashes `next` and calls
/// it after deactivation is a bug the host cannot prevent, and this says so
/// rather than pretending otherwise.
dynamic Function(dynamic) compose(
    List<Binding> bindings, dynamic Function(dynamic) base) {
  var next = base;
  for (var i = bindings.length - 1; i >= 0; i--) {
    // `fn` and `inner` are declared INSIDE the loop, so each layer closes
    // over its own pair. Dart captures the variable rather than the value,
    // and hoisting either would leave every layer calling the last one.
    final fn = bindings[i].fn;
    final inner = next;
    next = (arg) => fn(inner, arg);
  }
  return next;
}

/// The winner and the losers on a provider point.
class Picked {
  final Binding? winner;
  final List<String> shadowed;
  Picked(this.winner, this.shadowed);
}

/// At most one live implementation (section 6.3). The winner is the highest
/// band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
/// silently ignored.
Picked pointProvider(List<Binding> bindings, dynamic spec) {
  if (bindings.isEmpty) return Picked(null, []);

  if (t.truthy(t.get(spec, 'exclusive')) && bindings.length > 1) {
    final refs = bindings.map((b) => b.ref).toList()..sort();
    t.fail(
        'plugin_point_exclusive',
        'point is exclusive and has ${bindings.length} bindings: '
            '${refs.join(', ')}',
        {'refs': refs});
  }

  final ranked = t.stableSortBy(bindings, (b) => [-b.band, b.ref]);
  return Picked(ranked[0], ranked.sublist(1).map((b) => b.ref).toList());
}
