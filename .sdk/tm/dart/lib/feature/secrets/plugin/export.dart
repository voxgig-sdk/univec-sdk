// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/export.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// Exports (section 11).
///
/// An instance publishes values for other plugins and for the application.
/// Read with `host.exports('retry$fast/client')`.
///
/// THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client` resolves
/// to the UNTAGGED instance if one exists; if not, and exactly one tagged
/// instance exports that key, it resolves to that one; if two do, it is
/// `plugin_export_ambiguous` - deliberately diverging from seneca's silent
/// last-wins, because with multi-instance as a headline feature an
/// ambiguous alias is a defect waiting for production.
library;

import 'types.dart' as t;
import 'ref.dart' as r;

/// One published value. An internal shape, never a corpus value.
class Exported {
  final String ref;
  final String key;
  final dynamic value;
  Exported(this.ref, this.key, this.value);
}

dynamic resolveExport(String spec, List<Exported> exported) {
  final cut = spec.indexOf('/');
  if (cut < 0) {
    t.fail('plugin_export_ambiguous', 'export spec needs a key: $spec',
        {'spec': spec});
  }
  final head = spec.substring(0, cut);
  final key = spec.substring(cut + 1);

  // A fully qualified ref: exactly one answer or none.
  final want = r.canon(head);
  for (final e in exported) {
    if (e.ref == want && e.key == key) return e.value;
  }

  // An alias: the name, not a ref. Look at every instance of it.
  final byname =
      exported.where((e) => r.refName(e.ref) == head && e.key == key).toList();
  if (byname.isEmpty) return null;

  for (final e in byname) {
    if ((r.parseRef(e.ref)['tag'] as String).isEmpty) return e.value;
  }
  if (byname.length == 1) return byname[0].value;

  final refs = byname.map((e) => e.ref).toList()..sort();
  t.fail(
      'plugin_export_ambiguous',
      'alias $spec matches ${refs.length} instances: ${refs.join(', ')}',
      {'spec': spec, 'refs': refs});
}
