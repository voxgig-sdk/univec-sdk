import 'voxgig_struct.dart' as vs;

dynamic prepareQuery(dynamic ctx) {
  final point = ctx.point;
  final params = point.params ?? [];
  final reqmatch = ctx.reqmatch ?? {};

  final out = <String, dynamic>{};
  for (final item in vs.items(reqmatch)) {
    final key = item[0];
    final val = item[1];
    if (null != val && !(params as List).contains(key)) {
      out[key] = val;
    }
  }

  return out;
}
