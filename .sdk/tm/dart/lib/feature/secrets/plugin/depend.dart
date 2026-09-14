// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/depend.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Dependency cardinality, policy, and the restart graph (section 11.3).
///
/// TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
/// because only it knows what it can cope with:
///
///                | static (default)          | dynamic
///   -------------|---------------------------|--------------------------
///   mandatory    | unmet -> pending;         | unmet -> pending;
///   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
///                |          recursively      |          notified
///   -------------|---------------------------|--------------------------
///   optional:true| never gates activation;   | never gates activation;
///                | a change deactivates and  | a change is a
///                | reactivates               | notification, nothing else
///
/// `dynamic` means the plugin has said, IN WRITING, that it can survive its
/// provider being swapped underneath it. It is not the default because most
/// plugins cannot, and the cost of wrongly assuming they can is a live
/// instance holding a dead reference.
///
/// The rebinding-preference axis is deliberately omitted. OSGi has
/// reluctant vs greedy and it is a knob every author must understand to read
/// anyone else's component; we take always-reluctant. Three axes were more
/// than the model can carry across twenty ports.
library;

import 'types.dart' as t;
import 'ref.dart' as r;

/// One node of the requirement graph. An internal shape, never a corpus
/// value.
class GraphNode {
  final String ref;
  final List<String> provides;
  final List<dynamic> requires;
  GraphNode(this.ref, this.provides, this.requires);
}

/// A bare string is shorthand for `{name}`.
Map<String, dynamic> normRequire(dynamic raw) {
  if (raw is String) return {'name': raw};
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return {};
}

/// The requirements a definition declared, normalized.
///
/// BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
///
/// The instance-level `policy` and `optional` list are how a DOCUMENT states
/// the axis without editing the definition, and they apply to every
/// requirement. The per-requirement form is the one section 11.1's object
/// syntax exists for, and it is strictly more expressive: an instance that
/// is `static` on its store and `dynamic` on its metrics cannot be written
/// at all at the instance level.
///
/// `optional` unions rather than overriding - both spellings are statements
/// that this requirement need not gate activation, and there is no reading
/// under which one of them means "actually, mandatory".
List<Map<String, dynamic>> requirements(dynamic options) {
  final raw = (t.get(options, 'requires') ?? []) as List;
  final marked = t.get(options, 'optional');
  final fallback = t.get(options, 'policy');

  return raw.map((item) {
    final req = normRequire(item);
    if (t.truthy(req['optional']) ||
        (marked is List && marked.contains(req['name']))) {
      req['optional'] = true;
    }
    if (req['policy'] == null && fallback != null) req['policy'] = fallback;
    return req;
  }).toList();
}

/// Does losing this requirement's SELECTED provider restart the consumer?
/// The mandatory ones under `static`, and the `static` optional ones - both
/// make a capability change deactivate and reactivate. `dynamic` never
/// restarts.
bool restartsOnLoss(dynamic req) =>
    (t.get(req, 'policy') ?? 'static') != 'dynamic';

/// Does an unmet requirement keep the consumer out of `live`?
///
/// Cardinality alone decides this, NOT policy. `dynamic` is a statement
/// about surviving a SWAP, not about starting without the thing at all - a
/// mandatory-dynamic consumer still waits in `pending` for its first
/// provider.
bool gatesActivation(dynamic req) => t.get(req, 'optional') != true;

/// Edges that can cause a restart, which is exactly the set a cycle must be
/// detected over (section 11.3).
///
/// ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
/// exclusion was for: two plugins that optionally and dynamically consume
/// each other's capabilities both activate happily, neither gates on the
/// other, and each is merely notified when the other appears. Nothing
/// restarts, so nothing oscillates. An earlier draft of section 11.3
/// excluded EVERY optional edge and thereby admitted the non-terminating
/// case it was trying to permit.
bool restartCausing(dynamic req) =>
    gatesActivation(req) || restartsOnLoss(req);

/// A cycle through restart-causing requirements is
/// `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
/// because the failure it describes is a non-terminating reconcile and the
/// only safe time to report that is before it starts.
///
/// The graph is over capabilities, not refs: an edge runs from a consumer to
/// EVERY node that provides what it needs, because any of them could be the
/// one selected and a cycle through any is a cycle. A node also satisfies
/// its own name as a ref (section 11.1), which is why the ref is a provider
/// of itself here.
List<String>? dependencyCycle(List<GraphNode> nodes) {
  // TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are matched
  // differently - a capability by its exact name, a ref through the
  // canonical spelling (section 4 rule 5) - and one map keyed by both can
  // only do one of them. Keyed by both and looked up raw, as this was, a
  // cycle spelled `a$`/`b$` found no providers and EVADED the load-time
  // check that exists to catch a non-terminating reconcile.
  final bycap = <String, List<String>>{};
  final isref = <String>{};
  for (final n in nodes) {
    isref.add(n.ref);
    for (final cap in n.provides) {
      bycap.putIfAbsent(cap, () => []).add(n.ref);
    }
  }

  final edges = <String, List<String>>{};
  for (final n in nodes) {
    final out = <String>[];
    for (final req in n.requires) {
      if (!restartCausing(req)) continue;
      final reqname = t.get(req, 'name');
      final from = <String>[...(bycap[reqname] ?? const <String>[])];
      // A node satisfies its own name AS A REF (section 11.1),
      // canonically - exactly what `providersOf` does at runtime. `canon`
      // hands back a name no ref could have unchanged, and no instance ref
      // can equal one, so it is the tolerant test.
      final asref = r.canon(reqname);
      if (isref.contains(asref) && !from.contains(asref)) from.add(asref);
      for (final p in from) {
        if (p != n.ref && !out.contains(p)) out.add(p);
      }
    }
    edges[n.ref] = out..sort();
  }

  // Iterative DFS with an explicit stack: twenty ports, and several of them
  // have no recursion budget worth relying on.
  const white = 0, grey = 1, black = 2;
  final colour = {for (final n in nodes) n.ref: white};

  for (final start in edges.keys.toList()..sort()) {
    if (colour[start] != white) continue;

    final path = <String>[start];
    final stack = <List<dynamic>>[
      [start, 0]
    ];
    colour[start] = grey;

    while (stack.isNotEmpty) {
      final top = stack.last;
      final node = top[0] as String;
      if ((top[1] as int) >= edges[node]!.length) {
        colour[node] = black;
        stack.removeLast();
        path.removeLast();
        continue;
      }
      final next = edges[node]![top[1] as int];
      top[1] = (top[1] as int) + 1;
      if (colour[next] == grey) {
        // Report the cycle itself, not the walk that found it.
        return [...path.sublist(path.indexOf(next)), next];
      }
      if (colour[next] == black) continue;
      colour[next] = grey;
      path.add(next);
      stack.add([next, 0]);
    }
  }
  return null;
}

/// Raise on a cycle, naming it. Separate from the detector so the detector
/// stays pure and corpus-testable.
void checkCycle(List<GraphNode> nodes) {
  final cycle = dependencyCycle(nodes);
  if (cycle == null) return;
  t.fail('plugin_dependency_cycle', 'requirements cycle: ${cycle.join(' -> ')}',
      {'cycle': cycle});
}
