// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/config.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// The declarative document (section 9): normalization, and the ten-level
/// precedence ladder.
///
/// TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
///
/// `normalizeConfig` normalizes STRUCTURE and ENTRY KEYS. It does not merge
/// options, and cannot: section 9.4 makes merge behaviour a property of the
/// definition's option SHAPE, which normalization has never seen. A
/// normalizer that flattened the option layers would make `$MERGE: append`
/// unimplementable at load time, because the layers it must concatenate
/// would already be collapsed.
///
/// `resolveOptions` applies the ladder, and it is the only place that knows
/// the shape.
library;

import 'types.dart' as t;
import 'ref.dart' as r;

const mergeWords = ['replace', 'append'];

class _Entries {
  final Map<String, dynamic> map = {};
  final List<String> order = [];
}

/// Both document forms reduce to {ref -> entry} plus the order the form
/// implies: array POSITION for the array form, sorted refs for the map form.
_Entries _entries(dynamic src) {
  final out = _Entries();
  if (src == null) return out;

  if (src is List) {
    for (final item in src) {
      final ref = r.canonRef(t.get(item, 'ref'));
      out.map[ref] = item;
      out.order.add(ref);
    }
    return out;
  }

  // Map-form refs arrive as KEYS, through a different path than an array
  // element's `ref` field - and must canonicalize the same way.
  for (final key in t.sortedKeys(src)) {
    out.map[r.canonRef(key)] = t.get(src, key);
  }
  // Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs sort
  // identically under all three, so only mixed input discriminates: '@' is
  // 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. Dart's String.compareTo
  // is UTF-16 code unit order, which is exactly that for a ref.
  out.order.addAll(out.map.keys.toList()..sort());
  return out;
}

void _checkReserved(String ref, List reserved) {
  if (!reserved.contains(r.refName(ref))) return;
  t.fail('plugin_ref_reserved', 'ref is reserved by the host: $ref',
      {'ref': ref});
}

/// PRESENCE decides, not truthiness and not null. A JSON `null` is a present
/// value in JavaScript (`undefined !== null`), so it must be one here.
dynamic _pick(dynamic src, String key, dynamic dflt) =>
    t.has(src, key) ? t.get(src, key) : dflt;

Map<String, dynamic> normalizeConfig(dynamic input) {
  final doc = t.get(input, 'doc') ?? {};
  final keys = t.get(input, 'keys') ?? {};
  final ikey = (t.get(keys, 'instance') ?? 'instance') as String;
  final dkey = (t.get(keys, 'default') ?? 'default') as String;
  final reserved = (t.get(input, 'reserved') ?? []) as List;
  final profile = t.get(input, 'profile');

  // The rename is applied at TWO PLACES AND NO OTHERS: the document root,
  // and every profile.<name> overlay root (section 9.1). A rename applied
  // only at the root would leave `profile.prod.sdk` untranslated and
  // silently drop every environment override the host depends on. Recursing
  // further would be worse: option data is the definition's.
  final basedef = t.get(doc, dkey) ?? {};
  var overlay = profile == null ? null : t.get(t.get(doc, 'profile'), profile);
  if (overlay is! Map) overlay = {};
  final overdef = t.get(overlay, dkey) ?? {};

  final base = _entries(t.get(doc, ikey));
  final over = _entries(t.get(overlay, ikey));

  for (final group in [
    base.map.keys.toList(),
    over.map.keys.toList(),
    t.sortedKeys(basedef),
    t.sortedKeys(overdef)
  ]) {
    for (final ref in group) {
      _checkReserved(ref, reserved);
    }
  }

  // A PARTIAL ARRAY IS NOT A FILTER (section 9.1). sdkgen learned this the
  // hard way: deriving order from a partial array silently dropped
  // config-activated features. Refs in the base but absent from the overlay
  // still load, in sorted position AFTER the listed ones. A profile may also
  // INTRODUCE a ref the base never declared. The remainder keeps the BASE's
  // own order.
  final order = <String>[];
  for (final ref in [...over.order, ...base.order]) {
    if (!order.contains(ref)) order.add(ref);
  }

  final instance = <String, dynamic>{};
  for (var i = 0; i < order.length; i++) {
    final ref = order[i];
    final b = base.map[ref];
    final o = over.map[ref];

    // MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
    // (section 9.3). A safety rule, not a tidiness one: if the overlay had
    // its defaults filled in before merging it would carry a synthesized
    // active:true and overwrite a base's false - silently re-enabling a
    // deliberately disabled integration in production.
    final block = _pick(o, 'order', _pick(b, 'order', null));

    // Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
    final nm = r.refName(ref);
    final layers = <dynamic>[];
    for (final src in [t.get(basedef, nm), b, t.get(overdef, nm), o]) {
      if (t.has(src, 'options')) layers.add(t.get(src, 'options'));
    }

    final ent = <String, dynamic>{
      'pos': i,
      'active': _pick(o, 'active', _pick(b, 'active', true)),
      'start': _pick(o, 'start', _pick(b, 'start', 'eager')),
      'optionlayers': layers,
    };
    if (block != null) ent['order'] = block;
    instance[ref] = ent;
  }

  // `default` DECLARES NOTHING (section 9.3). It is a base for every
  // instance of that definition; it does not create one, and an entry for a
  // name with no instances is inert rather than an error - which is what
  // makes a shared library of defaults shippable.
  final defout = <String, dynamic>{};
  for (final k in t.sortedKeys(basedef)) {
    defout[k] = t.get(basedef, k);
  }
  for (final k in t.sortedKeys(overdef)) {
    defout[k] = t.get(overdef, k);
  }

  return {'instance': instance, 'order': order, 'default': defout};
}

/// Section 9.4: N is an integer of at least 1, and everything else is an
/// error.
///
/// `{"deep": 0}` is rejected DESPITE having an obvious reading, because
/// "replace at this key" already has a spelling and two spellings for one
/// behaviour is the defect class this repo exists to avoid.
void checkShape(dynamic shape) {
  if (shape is! Map) return;
  for (final k in t.sortedKeys(shape)) {
    final v = t.get(shape, k);
    if (!t.has(v, r'$MERGE')) continue;
    final directive = t.get(v, r'$MERGE');

    if (directive is String) {
      if (mergeWords.contains(directive)) continue;
      t.fail('plugin_shape_invalid', 'invalid \$MERGE directive at $k: $directive',
          {'key': k, 'directive': directive});
    }
    if (t.has(directive, 'deep')) {
      final n = t.get(directive, 'deep');
      // `true is int` is false in dart, so the boolean case falls out for
      // free here - unlike python, where it does not.
      if (n is int && n >= 1) continue;
      t.fail('plugin_shape_invalid',
          'invalid \$MERGE deep at $k: ${t.encode(n)}',
          {'key': k, 'directive': directive});
    }
    t.fail('plugin_shape_invalid',
        'invalid \$MERGE directive at $k: ${t.encode(directive)}',
        {'key': k, 'directive': directive});
  }
}

/// The shape's non-directive values are the level-1 defaults.
Map<String, dynamic> _defaultsOf(dynamic shape) {
  final out = <String, dynamic>{};
  for (final k in t.sortedKeys(shape)) {
    final v = t.get(shape, k);
    if (t.has(v, r'$MERGE')) continue;
    out[k] = v;
  }
  return out;
}

dynamic _optsOf(dynamic src, String key) {
  if (src == null) return null;
  // The array form is equivalent to the map form (section 9.1).
  if (src is List) {
    for (final item in src) {
      if (r.canonRef(t.get(item, 'ref')) == key) return t.get(item, 'options');
    }
    return null;
  }
  for (final k in t.sortedKeys(src)) {
    if (r.canonRef(k) != key) continue;
    final entry = t.get(src, k);
    return entry is Map ? t.get(entry, 'options') : null;
  }
  return null;
}

/// Merge N levels below this key, replace below that.
dynamic _deepTo(dynamic base, dynamic over, int n) {
  if (n <= 0) return over;
  if (base is! Map || over is! Map) return over;
  final out = Map<String, dynamic>.from(base);
  for (final k in t.sortedKeys(over)) {
    out[k] = _deepTo(out[k], over[k], n - 1);
  }
  return out;
}

/// Merge ONE layer onto the accumulator, honouring the shape's directives.
/// The directive holds at EVERY precedence level, not only between document
/// levels - section 9.4 makes it a property of the shape, which does not
/// know which layer a value arrived from.
dynamic _mergeOne(dynamic base, dynamic over, dynamic shape) {
  if (over == null) return base;
  if (base is! Map || over is! Map) return over;

  final out = Map<String, dynamic>.from(base);
  for (final k in t.sortedKeys(over)) {
    final o = over[k];
    final b = out[k];
    final directive = t.get(t.get(shape, k), r'$MERGE');

    if (directive == 'replace') {
      out[k] = o;
    } else if (directive == 'append') {
      final bl = b is List ? b : [];
      final ol = o is List ? o : [o];
      out[k] = [...bl, ...ol];
    } else if (t.has(directive, 'deep')) {
      out[k] = _deepTo(b, o, t.get(directive, 'deep') as int);
    } else {
      // Library default: deep for maps, REPLACE for lists. struct.merge is
      // element-wise by index, which for option maps is nearly always wrong
      // - ["a"] over ["x","y","z"] yielding ["a","y","z"] is the defect
      // station hit on secrets.providers.
      out[k] = (b is Map && o is Map) ? _mergeOne(b, o, null) : o;
    }
  }
  return out;
}

Map<String, dynamic> resolveOptions(dynamic input) {
  final shape = t.get(input, 'shape') ?? {};
  checkShape(shape);

  final ref = r.canonRef(t.get(input, 'ref'));
  final name = r.refName(ref);
  final doc = t.get(input, 'doc') ?? {};
  final profile = t.get(input, 'profile');

  var overlay = profile == null ? null : t.get(t.get(doc, 'profile'), profile);
  if (overlay is! Map) overlay = {};

  // ONE ordered merge, lowest to highest. Levels 3-6 are not two namespaces
  // collapsed separately and composed afterwards: that inverts the rule that
  // PROFILE SPECIFICITY OUTRANKS DEFINITION SPECIFICITY, so a prod
  // per-definition default would lose to a base instance value.
  final layers = [
    _defaultsOf(shape), // 1
    t.get(input, 'hostdefaults'), // 2
    _optsOf(t.get(doc, 'default'), name), // 3
    _optsOf(t.get(doc, 'instance'), ref), // 4
    _optsOf(t.get(overlay, 'default'), name), // 5
    _optsOf(t.get(overlay, 'instance'), ref), // 6
    t.get(input, 'env'), // 7
    t.get(input, 'hostoptions'), // 8
    t.get(input, 'loadoptions'), // 9
    t.get(input, 'patch'), // 10
  ];

  dynamic out = <String, dynamic>{};
  for (final layer in layers) {
    if (layer == null) continue;
    out = _mergeOne(out, layer, shape);
  }
  return out as Map<String, dynamic>;
}
