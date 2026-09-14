// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/env.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Environment overrides (section 9.5) - level 7 of the ladder.
///
/// One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
///
///   VOXGIG_PLUGIN_PROFILE            the profile name
///   VOXGIG_PLUGIN_<REF>_<PATH>       one option
///   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
///
/// THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
/// OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` -> `_`.
/// But `_` is legal in a name and in a tag, and the mapping folds case, so
/// `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.
///
/// Rather than restrict a grammar the rest of the stack already uses, the
/// host DETECTS THE COLLISION: it encodes every ref it holds, and a key two
/// refs claim is `plugin_env_ambiguous`, naming both.
library;

import 'dart:convert';

import 'types.dart' as t;
import 'ref.dart' as r;

const envPrefix = 'VOXGIG_PLUGIN_';

/// `retry$fast` -> `RETRY__FAST`.
String encodeRef(String ref) =>
    ref.replaceAll(r'$', '__').replaceAll('.', '_').toUpperCase();

/// Values parse as JSON, FALLING BACK TO STRING - so `8080` is a number,
/// `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
/// looks like rather than a parse error. `dart:convert` is the SDK's own
/// library, not a package: section 16 bars a `pubspec.yaml` dependency
/// list, which this port does not have.
dynamic _parseValue(dynamic value) {
  try {
    return jsonDecode(value as String);
  } catch (_) {
    return value;
  }
}

List<String> _split(dynamic value) => '$value'
    .split(',')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

void _checkReserved(String ref, List reserved) {
  if (!reserved.contains(r.refName(ref))) return;
  t.fail('plugin_ref_reserved', 'ref is reserved by the host: $ref',
      {'ref': ref});
}

Map<String, dynamic> applyEnv(dynamic input) {
  final env = t.get(input, 'env') ?? {};
  final refs = ((t.get(input, 'refs') ?? []) as List).map(r.canonRef).toList();
  final reserved = (t.get(input, 'reserved') ?? []) as List;
  final out = <String, dynamic>{
    'options': <String, dynamic>{},
    'active': <String>[],
    'inactive': <String>[]
  };

  // Encode every ref the host holds, and refuse a key that two of them
  // claim. Done up front so the collision is reported even when no
  // environment variable exercises it - a latent ambiguity is still an
  // ambiguity, and finding it at deploy time is the failure this exists to
  // prevent.
  final byencoded = <String, List<String>>{};
  for (final ref in refs) {
    byencoded.putIfAbsent(encodeRef(ref), () => []).add(ref);
  }
  for (final e in t.sortedKeys(byencoded)) {
    if (byencoded[e]!.length <= 1) continue;
    final pair = List<String>.from(byencoded[e]!)..sort();
    t.fail(
        'plugin_env_ambiguous',
        'refs collide in the environment encoding as $e: ${pair.join(', ')}',
        {'encoded': e, 'refs': pair});
  }

  // Longest encoded ref first, so `retry$fast` wins over `retry` on
  // `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
  final encoded =
      t.stableSortBy(t.sortedKeys(byencoded), (e) => [-e.length]);

  for (final key in t.sortedKeys(env)) {
    if (!key.startsWith(envPrefix)) continue;
    final rest = key.substring(envPrefix.length);

    if (rest == 'PROFILE') {
      out['profile'] = t.get(env, key);
      continue;
    }

    if (rest == 'ACTIVE' || rest == 'INACTIVE') {
      for (final raw in _split(t.get(env, key))) {
        final ref = r.canonRef(raw);
        // The reservation covers EVERY input layer (section 9.1).
        // VOXGIG_PLUGIN_INACTIVE=station is easier to set than editing a
        // config file, and INACTIVE has the final word - so guarding
        // documents alone would leave the one lever this mechanism exists
        // to deny wide open.
        _checkReserved(ref, reserved);
        (out[rest == 'ACTIVE' ? 'active' : 'inactive'] as List).add(ref);
      }
      continue;
    }

    final enc = encoded
        .where((e) => rest == e || rest.startsWith('${e}_'))
        .firstOrNull;
    if (enc == null) continue; // not for any ref this host holds

    final ref = byencoded[enc]![0];
    _checkReserved(ref, reserved);

    if (rest == enc) continue; // a ref with no path sets nothing

    final path = rest.substring(enc.length + 1).toLowerCase().split('_');

    final options = out['options'] as Map<String, dynamic>;
    var node = options[ref];
    if (node is! Map) {
      node = <String, dynamic>{};
      options[ref] = node;
    }
    for (var i = 0; i < path.length - 1; i++) {
      var child = (node as Map)[path[i]];
      if (child is! Map) {
        child = <String, dynamic>{};
        node[path[i]] = child;
      }
      node = child;
    }
    (node as Map)[path[path.length - 1]] = _parseValue(t.get(env, key));
  }

  return out;
}
