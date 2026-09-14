// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/capability.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Capabilities (section 11.1).
///
/// A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a
/// dependency on something that can do the job, and which instance is doing
/// it is exactly the configuration detail a plugin must not care about.
///
/// But A BINDING IS TO AN INSTANCE, not to a capability, which is what
/// decides behaviour when the bound provider leaves while another match
/// remains.
library;

import 'types.dart' as t;
import 'version.dart' as v;

/// Rank the matching live providers and return them best-first: highest
/// `version`, then LOWEST `priority` (default 0), then declaration position
/// `pos` ascending.
///
/// `priority` is a field on the capability rather than section 7's `order`
/// band, because bands live on POINT BINDINGS: a provider may have several
/// bindings with different bands, or none at all, so a rank reaching for
/// one would be undefined in the common case.
///
/// Without a total rank, "any provider satisfies" is true of the GRAPH and
/// useless to the PLUGIN - two ports could bind different `store`
/// instances, both resolve green, and behave differently, which is
/// precisely the divergence a shared corpus exists to catch.
List<dynamic> resolveCapability(dynamic req, dynamic candidates) {
  final hits = (candidates as List)
      .where((c) => matches(req, t.get(c, 'provides') ?? {}))
      .toList();
  return t.stableSortBy(hits, rankKey);
}

/// An ABSENT version sorts LAST, whatever the other is - "no version" loses
/// to every version rather than being read as 0.0.0. The leading flag is
/// what expresses that in a sort KEY rather than a comparator.
List<Object> rankKey(dynamic cand) {
  final prov = t.get(cand, 'provides') ?? {};
  final version = t.get(prov, 'version');
  return [
    version == null ? 1 : 0,
    version == null
        ? <Object>[0, 0, 0]
        : v.versionParts(version as String).map((n) => -n).toList().cast<Object>(),
    (t.get(prov, 'priority') ?? 0) as Object,
    (t.get(cand, 'pos') ?? 0) as Object,
  ];
}

bool matches(dynamic req, dynamic prov) {
  if (t.get(req, 'name') != t.get(prov, 'name')) return false;

  if (t.get(req, 'range') != null) {
    if (t.get(prov, 'version') == null) return false;
    if (!v.satisfiesq(t.get(prov, 'version'), t.get(req, 'range'))) return false;
  }

  // `match` is checked against the provider's `attrs`, key by key. A key the
  // provider does not carry is a miss, not a pass: a requirement asking for
  // `transactional: true` must not be satisfied by a provider that never
  // said.
  final want = t.get(req, 'match');
  if (want != null) {
    final attrs = t.get(prov, 'attrs') ?? {};
    for (final k in t.sortedKeys(want)) {
      if (!t.has(attrs, k)) return false;
      if (!matchValue(t.get(want, k), t.get(attrs, k))) return false;
    }
  }
  return true;
}

/// PARTIAL MATCH, RECURSING INTO MAPS (section 11.1).
///
/// Every leaf in the requirement must be present and equal in the
/// capability, keys not mentioned are not checked. Equality is by JSON TYPE
/// as well as value: `transactional: 1` does not satisfy
/// `transactional: true`. DART NEEDS NO GUARD FOR THAT - `true == 1` is
/// false, because `bool` and `int` are unrelated types with no coercion.
/// Python, PHP, Perl and Lua all need one, and `capability/match` pins the
/// behaviour for every port rather than trusting each language's `==`.
///
/// A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
bool matchValue(dynamic want, dynamic got) {
  if (want is Map) {
    if (got is! Map) return false;
    for (final k in t.sortedKeys(want)) {
      if (!got.containsKey(k)) return false;
      if (!matchValue(want[k], got[k])) return false;
    }
    return true;
  }
  if (want is List) {
    if (got is! List || want.length != got.length) return false;
    for (var i = 0; i < want.length; i++) {
      if (!matchValue(want[i], got[i])) return false;
    }
    return true;
  }
  return t.same(want, got);
}
