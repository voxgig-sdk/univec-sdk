import 'voxgig_struct.dart' as vs;

import 'MediaUtility.dart';
import 'ParamUtility.dart';

dynamic prepareHeaders(dynamic ctx) {
  final client = ctx.client;

  final options = client.options();

  final out =
      mediaHeaders(ctx.point, vs.clone(vs.getprop(options, 'headers', {})));

  // A header argument replaces a default of the same name, whatever its case.
  for (final arg in callArgs(ctx, 'header')) {
    if (null != arg['val']) {
      final wire = (arg['wire'] as String).toLowerCase();
      for (final key in List.from(out.keys)) {
        if (wire == key.toString().toLowerCase()) out.remove(key);
      }
      out[wire] = vs.stringify(arg['val']);
    }
  }

  // A cookie argument travels in the cookie header, form serialized and
  // percent-encoded, replacing a same-named cookie the caller's headers send.
  final sent =
      callArgs(ctx, 'cookie').where((arg) => null != arg['val']).toList();
  if (0 < sent.length) {
    final names = <String>[];
    for (final arg in sent) {
      if (vs.ismap(arg['val'])) {
        names.addAll(
            vs.keysof(arg['val']).map((key) => vs.escurl(key).toString()));
      } else {
        names.add(arg['wire'] as String);
      }
    }
    final kept = <String>[];
    for (final key in List.from(out.keys)) {
      if ('cookie' != key.toString().toLowerCase()) continue;
      if (out[key] is String) kept.addAll(cookieKeep(out[key], names));
      out.remove(key);
    }
    for (final arg in sent) {
      final pair = cookiePair(arg['wire'] as String, arg['val']);
      if ('' != pair) kept.add(pair);
    }
    if (0 < kept.length) out['cookie'] = kept.join('; ');
  }

  return out;
}

// The form style of a cookie parameter: a list repeats the name, a map sends
// its own keys, and every value is percent-encoded.
String cookiePair(String wire, dynamic val) {
  String esc(dynamic v) => vs.escurl(vs.stringify(v)).toString();
  final List<String> pairs = vs.islist(val)
      ? (val as List).map((item) => wire + '=' + esc(item)).toList()
      : vs.ismap(val)
          ? vs
              .keysof(val)
              .map((key) => vs.escurl(key).toString() + '=' + esc(val[key]))
              .toList()
          : [wire + '=' + esc(val)];
  return pairs.join('; ');
}

// The caller's cookie pieces with the named cookies removed: a cookie is one
// `;`-delimited piece, whatever its value holds.
List<String> cookieKeep(String header, List<String> names) {
  final kept = <String>[];
  for (final piece in header.split(';')) {
    final cookie = piece.trim();
    if ('' != cookie && !names.contains(cookie.split('=')[0].trim())) {
      kept.add(cookie);
    }
  }
  return kept;
}
