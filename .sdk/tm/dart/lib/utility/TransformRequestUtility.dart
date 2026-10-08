import 'voxgig_struct.dart' as vs;

import 'ParamUtility.dart';

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
    final reqform = vs.getprop(pointProp(point, 'transform'), 'req');
    final reqdata = vs.isfunc(reqform)
        ? reqform(ctx)
        : vs.transform(
            {'reqdata': omit(ctx.reqdata, routedArgNames(ctx))}, reqform);

    return stripAction(reqdata);
  } catch (err) {
    return utility.makeError(ctx, err);
  }
}

dynamic stripAction(dynamic reqdata) => omit(reqdata, [r'$action']);

// A header, cookie or query argument travels where prepareHeaders or
// prepareQuery sends it, so the body is built from the request data without it,
// unless the point marks it as a field the body keeps.
List<dynamic> routedArgNames(dynamic ctx) => [
      ...callArgs(ctx, 'header'),
      ...callArgs(ctx, 'cookie'),
      ...callArgs(ctx, 'query'),
    ].map((arg) => arg['name']).where((name) => !fieldArg(ctx, name)).toList();

bool fieldArg(dynamic ctx, dynamic name) => ['header', 'cookie', 'query'].any(
    (kind) => argList(ctx.point, kind).any((arg) =>
        name == vs.getprop(arg, 'name') && true == vs.getprop(arg, 'field')));

dynamic omit(dynamic reqdata, List<dynamic> names) {
  if (reqdata is! Map) return reqdata;
  if (!names.any((name) => reqdata.containsKey(name))) return reqdata;

  final body = <String, dynamic>{};
  for (final key in reqdata.keys) {
    if (!names.contains(key)) body[key.toString()] = reqdata[key];
  }
  return body;
}
