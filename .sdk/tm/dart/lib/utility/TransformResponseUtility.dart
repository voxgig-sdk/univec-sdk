import 'voxgig_struct.dart' as vs;

/* Convert data from response into a structure suitable for use as entity
 * data.
 *
 * The operation (op) property `resform` is used to perform the data
 * extraction.
 */
dynamic transformResponse(dynamic ctx) {
  final spec = ctx.spec;
  final result = ctx.result;
  final utility = ctx.utility;
  final point = ctx.point;

  if (null != spec) {
    spec.step = 'resform';
  }

  if (null == result || true != result.ok) {
    return null;
  }

  try {
    final resform = vs.getprop(point.transform, 'res');

    // The transform store is the result viewed as a node.
    final store = {
      'ok': result.ok,
      'status': result.status,
      'statusText': result.statusText,
      'headers': result.headers,
      'body': result.body,
      'resdata': result.resdata,
      'resmatch': result.resmatch,
    };

    final resdata =
        vs.isfunc(resform) ? resform(ctx) : vs.transform(store, resform);
    result.resdata = resdata;
    return resdata;
  } catch (err) {
    return utility.makeError(ctx, err);
  }
}
