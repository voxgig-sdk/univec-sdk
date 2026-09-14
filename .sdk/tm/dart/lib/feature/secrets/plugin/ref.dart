// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/ref.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Identity: name+tag, written `name$tag` (section 4).
///
/// The four pure functions, and the whole of what `ref` pins. They are the
/// first thing a new port implements and the first corpus section it
/// passes.
library;

import 'types.dart' as t;

/// Section 4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024.
///
/// `hasMatch` on an anchored pattern, and the anchors are `^` and `$`
/// WITHOUT `multiLine` - dart's `$` matches only at the end of input when
/// multiLine is off, so `'abc\n'` is rejected. Turning multiLine on here
/// would admit a ref grammar with a newline in it, which is the trap ruby
/// and java each document from the other side.
final _nameRe = RegExp(r'^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$');

/// Section 4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
///
/// The asymmetry with a name is deliberate: a tag MAY start with a digit
/// because auto-tagging assigns integer tags (`stripe$1`), and a tag admits
/// neither `@` nor `/` because a name is a package specifier and a tag is
/// not.
final _tagRe = RegExp(r'^[a-zA-Z0-9.~_-]+$');

const refMax = 1024;

bool checkName(dynamic name) =>
    name is String && name.isNotEmpty && name.length <= refMax &&
    _nameRe.hasMatch(name);

bool checkTag(dynamic tag) {
  if (tag is! String) return false;
  // The empty tag is an ordinary tag (section 4 rule 2). The
  // single-instance case writes no tag and never learns tags exist.
  if (tag.isEmpty) return true;
  return tag.length <= refMax && _tagRe.hasMatch(tag);
}

/// `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both give
/// tag ''.
Map<String, dynamic> parseRef(dynamic str) {
  if (str is! String) t.fail('plugin_bad_name', 'ref must be a string');
  // Split on the FIRST `$`. Nothing in the grammar decides this - `$` is in
  // neither character class - so the corpus is the arbiter (section 4 rule
  // 5), and it picks the split that blames the part actually at fault:
  // `a$b$c` is a good name with a bad tag, not the reverse.
  final cut = str.indexOf(r'$');
  final name = cut < 0 ? str : str.substring(0, cut);
  final tag = cut < 0 ? '' : str.substring(cut + 1);

  if (!checkName(name)) {
    t.fail('plugin_bad_name', 'invalid plugin name: $name', {'name': name});
  }
  if (!checkTag(tag)) {
    t.fail('plugin_bad_tag', 'invalid plugin tag: $tag',
        {'name': name, 'tag': tag});
  }
  return {'name': name, 'tag': tag};
}

/// The pair -> `name$tag`. An empty tag NEVER writes the separator, which
/// is the half of canonicalization `formatRef` owns: parse tolerates
/// `stripe$`, format never produces it, so a round trip is idempotent.
String formatRef(dynamic name, [dynamic tag]) {
  final t2 = tag ?? '';
  if (!checkName(name)) {
    t.fail('plugin_bad_name', 'invalid plugin name: $name', {'name': name});
  }
  if (!checkTag(t2)) {
    t.fail('plugin_bad_tag', 'invalid plugin tag: $t2',
        {'name': name, 'tag': t2});
  }
  return (t2 as String).isEmpty ? name as String : '$name\$$t2';
}

/// The canonical spelling of a ref. Section 4 rule 5: ports must
/// canonicalize before comparison.
String canonRef(dynamic str) {
  final r = parseRef(str);
  return formatRef(r['name'], r['tag']);
}

/// `canonRef` for the internal callers that want the input back unchanged
/// when it is not well formed. NEVER use it where a bad ref must be
/// reported - the corpus pins plugin_bad_name at every public entry.
String canon(dynamic str) {
  try {
    return canonRef(str);
  } on t.PluginError {
    return str as String;
  }
}

String refName(dynamic str) {
  try {
    return parseRef(str)['name'] as String;
  } on t.PluginError {
    return str as String;
  }
}
