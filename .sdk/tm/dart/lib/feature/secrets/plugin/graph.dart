// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/graph.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Whole-graph resolution (section 11.4) - a phase, not a discovery.
///
/// "Activate, and wait in `pending` if you must" is correct and, on its own,
/// produces a terrible experience: apply twenty instances against a registry
/// missing one thing and you get NINETEEN pending rows and no statement of
/// what is actually wrong.
///
/// `resolveGraph` is a PURE FUNCTION of the registry and the intended
/// activation set. No callbacks run, no state changes, nothing is touched.
/// It answers for the whole graph at once which instances can be live, and
/// for each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.
///
/// The failure mode being designed against is a famous one: OSGi's resolver
/// is correct and its diagnostics are legendarily unusable. A resolver that
/// says "blocked" without saying WHY has moved the problem rather than
/// solved it, so `why` is part of the contract and the corpus pins its
/// shape.
library;

import 'types.dart' as t;
import 'ref.dart' as r;
import 'capability.dart' as cap;
import 'version.dart' as v;

Map<String, dynamic> resolveGraph(dynamic nodes) {
  final byref = <String, dynamic>{};
  for (final n in nodes as List) {
    byref[t.get(n, 'ref') as String] = n;
  }

  final resolved = <String>{};

  // Fixed point: a node resolves when every mandatory requirement is met by
  // an ALREADY-RESOLVED provider. Iterating to a fixed point is what makes a
  // provider that is itself blocked propagate, rather than each node being
  // judged against the raw registry.
  var moved = true;
  while (moved) {
    moved = false;
    for (final n in nodes) {
      final ref = t.get(n, 'ref') as String;
      if (resolved.contains(ref)) continue;
      if (firstUnmet(n, byref, resolved) != null) continue;
      resolved.add(ref);
      moved = true;
    }
  }

  final blocked = <String, dynamic>{};
  for (final n in nodes) {
    final ref = t.get(n, 'ref') as String;
    if (resolved.contains(ref)) continue;
    final why = firstUnmet(n, byref, resolved);
    if (why != null) blocked[ref] = why;
  }

  return {
    'resolved': resolved.toList()..sort(),
    'blocked': (blocked.keys.toList()..sort()).map((r) => blocked[r]).toList(),
  };
}

/// The FIRST unmet requirement, with the most specific explanation
/// available. Order matters: "no provider at all" and "a provider at the
/// wrong version" are different problems and a reader must not have to guess
/// which they have.
Map<String, dynamic>? firstUnmet(
    dynamic node, Map<String, dynamic> byref, Set<String> resolved) {
  for (final req in (t.get(node, 'requires') ?? []) as List) {
    if (t.truthy(t.get(req, 'optional'))) continue;
    final name = t.get(req, 'name') as String;

    final all = graphCandidates(byref, name);
    if (all.isEmpty) return _why(node, name, {'kind': 'absent'});

    final ok = cap.resolveCapability(req, all);
    if (ok.isNotEmpty) {
      // A provider exists and matches - but if none of them is itself
      // resolved, this node is blocked BEHIND it, and the chain is the
      // useful answer rather than "unmet".
      if (ok.any((c) => resolved.contains(t.get(c, 'ref')))) continue;
      final chain = ok.map((c) => t.get(c, 'ref') as String).toList()..sort();
      return _why(node, name, {'kind': 'blocked', 'chain': chain});
    }

    // Providers exist and none matched. Say which test failed.
    final range = t.get(req, 'range');
    if (range != null) {
      final versions = all
          .map((c) => t.get(t.get(c, 'provides'), 'version'))
          .where((ver) => ver == null || !v.satisfiesq(ver, range))
          .map((ver) => (ver ?? '(none)') as String)
          .toList();
      if (versions.isNotEmpty) {
        return _why(node, name,
            {'kind': 'version', 'range': range, 'found': versions..sort()});
      }
    }

    final match = t.get(req, 'match');
    if (match != null) {
      for (final c in all) {
        final attrs = t.get(t.get(c, 'provides'), 'attrs') ?? {};
        for (final k in t.sortedKeys(match)) {
          if (t.has(attrs, k) &&
              cap.matchValue(t.get(match, k), t.get(attrs, k))) {
            continue;
          }
          return _why(node, name, {
            'kind': 'match',
            'failing': k,
            'want': t.get(match, k),
            'found': t.get(attrs, k)
          });
        }
      }
    }

    return _why(node, name, {'kind': 'absent'});
  }
  return null;
}

Map<String, dynamic> _why(dynamic node, String name, dynamic reason) =>
    {'ref': t.get(node, 'ref'), 'unmet': name, 'why': reason};

List<dynamic> graphCandidates(Map<String, dynamic> byref, String name) {
  final out = <dynamic>[];
  // A NODE SATISFIES ITS OWN REF (section 11.1), and the graph learned it
  // here. Considering only declared capabilities made `resolve` answer
  // `absent` about a provider sitting right there and live - section
  // 11.4's job is explaining the graph the runtime reconciles, and it was
  // explaining a different one.
  final asref = r.canon(name);
  for (final ref in t.sortedKeys(byref)) {
    final node = byref[ref];
    // The ref match WINS OUTRIGHT for that node, as at runtime: one
    // candidate, not two, for a node both named `b` and providing `b`.
    if (ref == asref) {
      out.add({
        'ref': t.get(node, 'ref'),
        'pos': t.get(node, 'pos') ?? 0,
        'provides': {'name': name}
      });
      continue;
    }
    for (final prov in (t.get(node, 'provides') ?? []) as List) {
      if (t.get(prov, 'name') != name) continue;
      out.add({
        'ref': t.get(node, 'ref'),
        'pos': t.get(node, 'pos') ?? 0,
        'provides': prov
      });
    }
  }
  return out;
}
