import 'voxgig_struct.dart' as vs;

/* Convert entity data or match query into a structure suitable for use as
 * request data.
 *
 * The operation (op) property `reqform` is used to perform the data
 * preparation.
 */
dynamic transformRequest(dynamic ctx) {
  final spec = ctx.spec;
  final utility = ctx.utility;
  final point = ctx.point;

  if (null != spec) {
    spec.step = 'reqform';
  }

  try {
    final reqform = vs.getprop(point.transform, 'req');
    final reqdata = vs.isfunc(reqform)
        ? reqform(ctx)
        : vs.transform({'reqdata': ctx.reqdata}, reqform);

    return reqdata;
  } catch (err) {
    return utility.makeError(ctx, err);
  }
}
