// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/order.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Ordering (section 7) - one rule, one place.
///
/// sdkgen grew two special cases in `makeOptions` (`test`, then `station`)
/// and the third was not far off. This sort is the whole replacement, and
/// the tiers are in this order for a reason:
///
///   1 constraints   before/after edges, by ref or by name
///   2 bands         integer, lower first, default 0
///   3 declaration   ties break by `pos`
///
/// CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
/// present. A band expresses a genuine cross-cutting layer; a constraint
/// expresses a relationship between two specific things; and a band chosen
/// by trial and error to fix an ordering bug is a bug wearing a number.
library;

import 'types.dart' as t;
import 'ref.dart' as r;

/// One node of the sort. An internal shape, never a corpus value.
class OrderNode {
  final String ref;
  final int pos;
  final dynamic order;
  OrderNode(this.ref, this.pos, this.order);
}

int orderBand(OrderNode b) => t.asInt(t.get(b.order ?? {}, 'band')) ?? 0;

/// Was a constraint stated? An absent value and an EMPTY LIST are both
/// no-constraint - and an empty list is TRUTHY in most languages, which is
/// exactly how this class of bug survives a reading.
bool orderDeclared(dynamic spec) {
  if (spec == null) return false;
  if (spec is List) return spec.any((one) => one != '');
  return spec != '';
}

/// One spelling or a LIST of them. A list fans out to the UNION of what each
/// names, so after: ['a','b'] means after BOTH, and the same instance named
/// twice - once by name, once by ref - is one edge.
///
/// Matching is by REF, or by NAME across all of that definition's instances
/// (section 7) - which is the whole reason the two spellings exist.
List<String> orderTargets(dynamic spec, List<OrderNode> nodes) {
  final specs = spec is List ? spec : [spec];
  final hit = <String>[];
  for (final one in specs) {
    for (final b in nodes) {
      if (hit.contains(b.ref)) continue;
      if (b.ref == one || r.refName(b.ref) == one) hit.add(b.ref);
    }
  }
  return hit;
}

List<String> resolveOrder(List<OrderNode> bindings, [dynamic pin]) {
  final nodes = bindings;
  final byref = {for (final b in nodes) b.ref: b};

  // Constraints are edges. A constraint naming an ABSENT binding is
  // satisfied VACUOUSLY (section 7) - a plugin ordered `after: 'test'` must
  // load in a host with no test plugin. That is sdkgen's __after__
  // behaviour, kept.
  final edges = {for (final b in nodes) b.ref: <String>[]};

  for (final b in nodes) {
    final block = b.order ?? {};
    if (orderDeclared(t.get(block, 'after'))) {
      for (final target in orderTargets(t.get(block, 'after'), nodes)) {
        edges[target]!.add(b.ref);
      }
    }
    if (orderDeclared(t.get(block, 'before'))) {
      edges[b.ref]!.addAll(orderTargets(t.get(block, 'before'), nodes));
    }
  }

  final indeg = {for (final b in nodes) b.ref: 0};
  for (final tos in edges.values) {
    for (final to in tos) {
      indeg[to] = indeg[to]! + 1;
    }
  }

  // Stable topological sort. Among ready nodes, band first (lower runs
  // first), then `pos` - the position the DOCUMENT visibly states, not the
  // order instances happened to load and not the incarnation `seq`.
  final out = <String>[];
  var ready = nodes.where((b) => indeg[b.ref] == 0).toList();

  while (ready.isNotEmpty) {
    ready = t.stableSortBy(ready, (b) => [orderBand(b), b.pos]);
    final next = ready.removeAt(0);
    out.add(next.ref);
    for (final to in edges[next.ref]!) {
      indeg[to] = indeg[to]! - 1;
      if (indeg[to] == 0) ready.add(byref[to]!);
    }
  }

  if (out.length != nodes.length) {
    final stuck =
        nodes.where((b) => !out.contains(b.ref)).map((b) => b.ref).toList();
    t.fail('plugin_order_cycle',
        'before/after constraints cycle: ${stuck.join(' -> ')}',
        {'cycle': stuck});
  }

  return applyPin(out, edges, pin);
}

/// A PIN IS NOT A CONSTRAINT (section 7).
///
/// Constraints and bands are negotiable by definition - they are what
/// plugins and documents say they want, and the sort's job is to satisfy
/// them all. A pin is the host stating a structural invariant of its own
/// architecture, which is a different kind of claim and must not lose a tie
/// to a document.
///
/// So a pin PLACES the binding at the named end, and an ordering that would
/// move it away is `plugin_order_pinned` - rejected, not honoured into a
/// broken wrap.
List<String> applyPin(
    List<String> order, Map<String, List<String>> edges, dynamic pin) {
  if (pin == null) return order;
  final out = List<String>.from(order);

  // SORTED, not insertion order. A pin map is data - it can arrive from a
  // host's own construction options in any order, and two names pinned to
  // the same end are order-sensitive (`{b:'first', a:'first'}` and
  // `{a:'first', b:'first'}` give different results). A dart map iterates
  // in insertion order and a Go map has no order at all, so leaving it
  // unstated made the same declaration mean different things in different
  // ports.
  for (final name in t.sortedKeys(pin)) {
    final want = t.get(pin, name);
    final idx = out.indexWhere((ref) => r.refName(ref) == name);
    if (idx < 0) continue;

    // `first`/`outermost` is index 0; `last`/`innermost` is the end.
    // Section 6.2 makes the first chain binding outermost, which is why the
    // vocabulary is positional and why the two spellings pair this way.
    final wantFirst = want == 'first' || want == 'outermost';
    final ref = out.removeAt(idx);
    if (wantFirst) {
      out.insert(0, ref);
    } else {
      out.add(ref);
    }
  }

  // Now check that the placement did not break a constraint. This is the
  // half that makes a pin a rejection rather than an override: the host
  // wins on position, but it does not get to silently discard a
  // relationship a plugin declared.
  final at = {for (var i = 0; i < out.length; i++) out[i]: i};
  for (final from in edges.keys) {
    for (final to in edges[from]!) {
      if (at[from]! <= at[to]!) continue;
      t.fail(
          'plugin_order_pinned',
          'a pin would move a binding an ordering constrains: '
              '$from must precede $to',
          {'before': from, 'after': to});
    }
  }
  return out;
}
