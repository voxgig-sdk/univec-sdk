// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/resolve.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Dynamic resolution (section 10.2) - name to candidate module ids.
///
/// PURE. It returns the ids a host WOULD try, in order; it does not load
/// anything. That separation is what lets the corpus pin resolution in
/// every language including those with no dynamic loading at all, and it is
/// why section 15.4 puts real module loading in per-port integration tests
/// rather than here.
library;

import 'types.dart' as t;

const defaultSources = [
  {
    'kind': 'module',
    'prefix': ['@voxgig/plugin-', 'voxgig-plugin-', 'plugin-', ''],
  }
];

List<String> resolveCandidates(String name, [dynamic sources]) {
  // A SCOPED NAME RESOLVES VERBATIM ONLY (section 10.2). `@acme/thing` is
  // already a package id; prefixing it produces
  // `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
  if (name.startsWith('@')) return [name];

  final list = (sources == null || (sources as List).isEmpty)
      ? defaultSources
      : sources;
  final out = <String>[];

  for (final src in list) {
    switch (t.get(src, 'kind')) {
      case 'module':
        var prefixes = t.get(src, 'prefix') as List?;
        if (prefixes == null || prefixes.isEmpty) prefixes = [''];
        for (final p in prefixes) {
          final id = '$p$name';
          if (!out.contains(id)) out.add(id);
        }
        break;
      case 'path':
        final dir = (t.get(src, 'dir') as String).replaceAll(RegExp(r'/+$'), '');
        final id = '$dir/$name';
        if (!out.contains(id)) out.add(id);
        break;
    }
  }
  return out;
}

/// A MODULE PATH IS NOT A NAME (section 10.2). The ref grammar starts a
/// name with a letter or `@`, so `./local/thing` is not a ref and never
/// reaches candidate generation - seneca allows a path where a plugin name
/// goes, and this design deliberately does not, because a ref is an ADDRESS
/// WITHIN A HOST and a path is a LOCATION ON A DISK.
List<dynamic> resolveFrom(dynamic from) => [from];
