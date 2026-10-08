import 'voxgig_struct.dart' as vs;

import 'ParamUtility.dart';

dynamic prepareQuery(dynamic ctx) {
  final point = ctx.point;
  final params = pointProp(point, 'params') ?? [];
  final reqmatch = ctx.reqmatch ?? {};

  // A path parameter travels in the path. The generated config lists them as
  // args.params, which prepareParams reads; params is the older list of names.
  final inpath = <dynamic>[...(params as List)];
  for (final p in argList(point, 'params')) {
    inpath.add(vs.getprop(p, 'name'));
  }

  // A query parameter travels under the name the definition gives it, its
  // orig, which the model may have renamed for the caller.
  final wire = <dynamic, String>{};
  final declared = <dynamic>[];
  for (final q in argList(point, 'query')) {
    final name = vs.getprop(q, 'name');
    if (name is String) {
      declared.add(name);
      final orig = vs.getprop(q, 'orig');
      if (orig is String && '' != orig) wire[name] = orig;
    }
  }

  // A header or cookie parameter travels in the headers, which prepareHeaders
  // fills, unless a query parameter shares its name: then both are sent.
  final elsewhere = <dynamic>[];
  for (final a in [...argList(point, 'header'), ...argList(point, 'cookie')]) {
    final name = vs.getprop(a, 'name');
    if (!declared.contains(name)) elsewhere.add(name);
  }

  final out = <String, dynamic>{};
  for (final item in vs.items(reqmatch)) {
    final key = item[0];
    final val = item[1];
    if (null != val &&
        r'$action' != key &&
        !inpath.contains(key) &&
        !elsewhere.contains(key)) {
      out[wire[key] ?? key.toString()] = val;
    }
  }

  // A create or update passes its query arguments in its data.
  for (final arg in callArgs(ctx, 'query')) {
    if (null != arg['val'] && !inpath.contains(arg['name'])) {
      out[arg['wire'] as String] = arg['val'];
    }
  }

  return out;
}
