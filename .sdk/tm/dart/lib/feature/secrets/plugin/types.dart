// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/types.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// The value model, the error type, and the JSON writer.
///
/// DART DRAWS ALMOST EVERY DISTINCTION THE MODEL NEEDS. `Map` is not
/// `List`, a map holds `null` as a value, `containsKey` separates an
/// authored null from an absent key, and `true == 1` is false. What it
/// does NOT give is a stable sort or an ordered map iteration that means
/// anything - see `stableSortBy` and `sortedKeys` below, both of which are
/// load-bearing rather than tidiness.
library;

/// Section 5.1's seven statuses, and no more.
const statuses = [
  'declared', 'loaded', 'pending', 'live', 'failed', 'loading', 'closing'
];

/// Section 12's detail keys, in the order a message renders them. FIXED,
/// not the map's: a message is a searchable log line, and a line whose
/// fields move between runs is not.
const detailOrder = [
  'ref', 'point', 'name', 'key', 'spec', 'refs', 'kind', 'directive',
  'cycle', 'holders', 'cause'
];

/// The value at a key, or null. Absence and null read the same here.
dynamic get(dynamic m, String k) => m is Map ? m[k] : null;

/// PRESENCE, which is what distinguishes an authored null from absence.
bool has(dynamic m, String k) => m is Map && m.containsKey(k);

/// The keys of a map, SORTED - every walk of a map goes through here.
///
/// A dart `Map` literal is a `LinkedHashMap`, so iteration is INSERTION
/// order. That is deterministic within one run and meaningless across two:
/// a document parsed from different byte order, or a registry rebuilt in a
/// different sequence, iterates differently. Every walk sorts.
List<String> sortedKeys(dynamic m) {
  if (m is! Map) return [];
  final out = m.keys.map((k) => k as String).toList();
  out.sort();
  return out;
}

/// JSON truthiness: null and false, and nothing else, are false. Dart has
/// no truthiness of its own - `if (0)` does not compile - so this is where
/// the model's rule is written down.
bool truthy(dynamic v) => !(v == null || v == false);

/// An INTEGER, and only when the value is one. Section 7's band is an
/// integer the document wrote as one; `true` and `'2'` are not bands, and
/// dart's `is int` excludes both.
int? asInt(dynamic v) {
  if (v is int) return v;
  if (v is double && v == v.floorToDouble()) return v.toInt();
  return null;
}

/// A STABLE sort by a comparable key.
///
/// DART'S `List.sort` IS NOT STABLE, and it is not stable in practice
/// rather than merely in the documentation: sorting two hundred elements
/// by a two-valued key visibly reorders equal ones. Section 7's
/// comparators fall through to a `pos` or ref tie-break that javascript's
/// stable sort resolves BY POSITION, so without this a teardown order
/// changes between two runs of the same process.
List<T> stableSortBy<T>(List<T> list, List<Object> Function(T) keyOf) {
  final decorated = <List<Object>>[];
  for (var i = 0; i < list.length; i++) {
    decorated.add([keyOf(list[i]), i]);
  }
  decorated.sort((a, b) {
    final c = compareKeys(a[0] as List<Object>, b[0] as List<Object>);
    return c != 0 ? c : (a[1] as int).compareTo(b[1] as int);
  });
  return decorated.map((d) => list[d[1] as int]).toList();
}

/// Compare two sort keys element by element. A key is a list of numbers,
/// strings and nested lists, which is what lets `rankKey` express "absent
/// version sorts last" as a leading flag rather than as a comparator.
int compareKeys(List<Object> a, List<Object> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final x = a[i], y = b[i];
    final c = (x is List && y is List)
        ? compareKeys(x.cast<Object>(), y.cast<Object>())
        : (x as Comparable).compareTo(y);
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}

/// JSON equality: same type, then same value.
///
/// `true == 1` is false in dart, so the bool guard the other dynamic ports
/// need is not required here. `1 == 1.0` IS true, as it is in ruby and
/// javascript, and no corpus entry turns on the difference.
bool same(dynamic a, dynamic b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !same(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List || b is List) {
    if (a is! List || b is! List || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!same(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map || b is Map) return false;
  return a == b;
}

/// COMPACT JSON. A whole double renders without its fraction, so `1.0` and
/// `1` spell the same - the corpus writes both and a message quoting one
/// must not depend on which. Written here rather than taken from
/// `dart:convert` because `jsonEncode` walks a map in insertion order and
/// throws on a value it does not know, and this needs sorted keys and
/// `"(opaque)"`.
String encode(dynamic v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is int) return '$v';
  if (v is double) return v == v.floorToDouble() ? '${v.toInt()}' : '$v';
  if (v is String) return encodeString(v);
  if (v is List) return '[${v.map(encode).join(',')}]';
  if (v is Map) {
    return '{${sortedKeys(v).map((k) => '${encodeString(k)}:${encode(v[k])}').join(',')}}';
  }
  return '"(opaque)"';
}

String encodeString(String s) {
  final b = StringBuffer('"');
  for (final c in s.codeUnits) {
    switch (c) {
      case 0x22: b.write('\\"'); break;
      case 0x5c: b.write('\\\\'); break;
      case 0x0a: b.write('\\n'); break;
      case 0x0d: b.write('\\r'); break;
      case 0x09: b.write('\\t'); break;
      default:
        if (c < 0x20) {
          b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          b.writeCharCode(c);
        }
    }
  }
  b.write('"');
  return b.toString();
}

/// Every error carries a section 12 code. Ports compare by CODE and never
/// by message: wording is a port's own business, and pinning the words
/// would make every translation a corpus change. The FORMAT, however, is
/// pinned - a parseable message is what makes a log searchable across
/// twenty languages.
class PluginError implements Exception {
  final String code;
  final String text;
  final Map<String, dynamic> details;
  final String message;

  PluginError(this.code, this.text, this.details)
      : message = formatError(code, text, details);

  @override
  String toString() => message;
}

/// `plugin/<code>: <text> [<key>=<value> ...]`
///
/// Values render as COMPACT JSON, so a value containing a space or a
/// bracket cannot break the parse, and a list renders as a JSON array. The
/// bracket is absent entirely when no field applies.
String formatError(String code, String text, Map<String, dynamic> details) {
  final parts = detailOrder
      .where((k) => details.containsKey(k))
      .map((k) => '$k=${encode(details[k])}')
      .toList();
  final tail = parts.isEmpty ? '' : ' [${parts.join(' ')}]';
  return 'plugin/$code: $text$tail';
}

/// Throw a section 12 error. One spelling, so every raise site reads the
/// same.
Never fail(String code, String text, [Map<String, dynamic>? details]) {
  throw PluginError(code, text, details ?? {});
}

/// The section 12 code of an error, or '' for one this library did not
/// throw. The corpus compares by code, so the driver needs one place that
/// knows how to read it.
String codeOf(Object e) => e is PluginError ? e.code : '';

String messageOf(Object e) => e is PluginError ? e.message : '$e';
