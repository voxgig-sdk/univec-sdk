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
