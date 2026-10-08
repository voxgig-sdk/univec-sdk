import 'voxgig_struct.dart' as vs;

/* Find value of a match parameter, possibly using an alias.
 *
 * The match parameter may have an alias key. For example, the parameter
 * `foo_id` may be aliased to `id` in the entity data.
 *
 * This function returns null rather than failing.
 */
dynamic param(dynamic ctx, dynamic paramdef) {
  final point = ctx.point;
  final spec = ctx.spec;
  final match = ctx.match;
  final reqmatch = ctx.reqmatch;
  final data = ctx.data;
  final reqdata = ctx.reqdata;

  // TODO: review this search algorithm

  final key =
      paramdef is String ? paramdef : vs.getprop(paramdef, 'name');

  final akey = null == point ? null : vs.getprop(point.alias, key);

  dynamic val = vs.getprop(reqmatch, key);

  if (null == val) {
    val = vs.getprop(match, key);
  }

  if (null == val && null != akey) {
    if (null != spec) {
      vs.setprop(spec.alias, akey, key);
    }

    val = vs.getprop(reqmatch, akey);
  }

  if (null == val) {
    val = vs.getprop(reqdata, key);
  }

  if (null == val) {
    val = vs.getprop(data, key);
  }

  if (null == val && null != akey) {
    val = vs.getprop(reqdata, akey);

    if (null == val) {
      val = vs.getprop(data, akey);
    }
  }

  return val;
}

// A point is the Point class, or the map a feature supplies in its place.
dynamic pointProp(dynamic point, String key) {
  if (null == point) return null;
  if (point is Map) return vs.getprop(point, key);
  switch (key) {
    case 'args':
      return point.args;
    case 'params':
      return point.params;
    case 'transform':
      return point.transform;
    case 'response':
      return point.response;
    case 'body':
      return point.body;
  }
  return null;
}

List<dynamic> argList(dynamic point, String kind) {
  final args = vs.getprop(pointProp(point, 'args'), kind);
  return args is List ? args : [];
}

// A declared header, cookie or query argument of the point, with the name it
// travels under and the value the call passes in its match or data.
List<Map<String, dynamic>> callArgs(dynamic ctx, String kind) {
  final out = <Map<String, dynamic>>[];
  for (final arg in argList(ctx.point, kind)) {
    final name = vs.getprop(arg, 'name');
    if (name is! String || '' == name) continue;
    final orig = vs.getprop(arg, 'orig');
    out.add({
      'name': name,
      'wire': (orig is String && '' != orig) ? orig : name,
      'val': vs.getprop(ctx.reqmatch, name) ?? vs.getprop(ctx.reqdata, name),
    });
  }
  return out;
}
