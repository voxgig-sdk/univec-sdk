// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/version.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Versions and ranges (section 11.2).
///
/// TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
/// concrete version. A requirement declares `range`. A requirement is
/// satisfied when the names match, the `match` passes, and the provider's
/// `version` falls inside the requirement's `range`.
///
/// That is the whole rule. There is no third field and no second
/// comparison - an earlier draft added a provider-side `compat` range,
/// which left three values and no statement of how they combine, and three
/// defensible readings of one declaration is worse than the ambiguity it
/// was introduced to fix.
library;

import 'types.dart' as t;

final _versionRe = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?$');

/// A COMPONENT IS BOUNDED, and the bound is the model's, not the host
/// language's. A dart `int` is 64-bit and javascript stops being exact past
/// 2**53, so `9223372036854775808.0.0` parsed to an exact value here and a
/// rounded one there. 2**31-1 is the smallest bound every target language
/// holds exactly, which makes it the model's.
const componentMax = 2147483647;

int _component(String digits, String whole, String field) {
  // BigInt, not int.parse: a component of forty digits overflows a 64-bit
  // int silently in a release build, and the check below would then pass
  // for a value that is plainly out of range.
  final value = BigInt.parse(digits);
  if (BigInt.from(componentMax) < value) {
    t.fail('plugin_bad_range',
        'version component out of range in $whole: $digits', {field: whole});
  }
  return value.toInt();
}

/// Two forms and no more (section 11.2):
///
///   '2.1'    >= 2.1.0 and < 3.0.0
///   '~2.1'   >= 2.1.0 and < 2.2.0
Map<String, dynamic> parseRange(dynamic range) {
  if (range is! String || range.isEmpty) {
    t.fail('plugin_bad_range', 'invalid range: $range', {'range': range});
  }
  final tilde = range.startsWith('~');
  final body = tilde ? range.substring(1) : range;
  final m = _versionRe.firstMatch(body);
  if (m == null) {
    t.fail('plugin_bad_range', 'invalid range: $range', {'range': range});
  }
  final major = _component(m.group(1)!, range, 'range');
  final minor = m.group(2) == null ? 0 : _component(m.group(2)!, range, 'range');
  final patch = m.group(3) == null ? 0 : _component(m.group(3)!, range, 'range');
  return {
    'lo': [major, minor, patch],
    'hi': tilde ? [major, minor + 1, 0] : [major + 1, 0, 0],
  };
}

List<int> parseVersion(dynamic version) {
  if (version is! String) {
    t.fail('plugin_bad_range', 'invalid version: $version',
        {'version': version});
  }
  final m = _versionRe.firstMatch(version);
  if (m == null) {
    t.fail('plugin_bad_range', 'invalid version: $version',
        {'version': version});
  }
  return [
    _component(m.group(1)!, version, 'version'),
    m.group(2) == null ? 0 : _component(m.group(2)!, version, 'version'),
    m.group(3) == null ? 0 : _component(m.group(3)!, version, 'version'),
  ];
}

int versionCmp(List<dynamic> a, List<dynamic> b) {
  for (var i = 0; i < 3; i++) {
    final x = (i < a.length ? a[i] : 0) as int;
    final y = (i < b.length ? b[i] : 0) as int;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// The one satisfaction predicate: lo <= version < hi.
bool satisfies(dynamic version, dynamic range) {
  final v = parseVersion(version);
  final r = parseRange(range);
  return versionCmp(v, r['lo'] as List) >= 0 &&
      versionCmp(v, r['hi'] as List) < 0;
}

/// `satisfies` for the internal callers that treat an unparseable version
/// or range as "does not satisfy" - Capability and Graph, both of which run
/// over data the corpus has already admitted.
bool satisfiesq(dynamic version, dynamic range) {
  try {
    return satisfies(version, range);
  } on t.PluginError {
    return false;
  }
}

/// The numeric parts of a version, or zeros - a SORT KEY, never a check.
List<int> versionParts(String text) {
  try {
    return parseVersion(text);
  } on t.PluginError {
    return [0, 0, 0];
  }
}
