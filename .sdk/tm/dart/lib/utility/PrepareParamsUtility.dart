import 'voxgig_struct.dart' as vs;

dynamic prepareParams(dynamic ctx) {
  final utility = ctx.utility;
  final findparam = utility.param;

  final point = ctx.point;

  final params = vs.getprop(point.args, 'params') ?? [];

  final out = <String, dynamic>{};
  for (final pd in params) {
    final val = findparam(ctx, pd);
    if (null != val) {
      out[vs.getprop(pd, 'name').toString()] = val;
    }
  }

  // TODO: review
  // out = validate(out, point.validate.params)

  return out;
}
