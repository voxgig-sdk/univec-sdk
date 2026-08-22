import '../UnivecError.dart';
import '../Result.dart';

import 'CleanUtility.dart';
import 'ErrUtility.dart';

dynamic makeError(dynamic ctx, [dynamic err]) {
  final op = ctx.op;
  final opname =
      (null == op || null == op.name) ? 'unknown operation' : op.name;

  final result = ctx.result ?? Result({});
  result.ok = false;

  final reserr = result.err;

  err ??= reserr;
  err ??= ctx.error('unknown', 'unknown error');

  // TODO: project name should come from config
  // avoids spurious changes between template and generated utility
  // applies for all utility files
  final msg = 'UnivecSDK: ' + opname.toString() + ': ' + errmsg(err);

  UnivecError sdkerr;
  if (err is UnivecError) {
    sdkerr = err;
    sdkerr.message = clean(ctx, msg);
  } else {
    final code = errcode(err);
    sdkerr = UnivecError('' == code ? 'unknown' : code, clean(ctx, msg), ctx);
  }

  if (null != result.err) {
    result.err = null;
  }

  final spec = ctx.spec;

  if (null != ctx.ctrl['explain']) {
    ctx.ctrl['explain']['err'] = {
      'code': sdkerr.code,
      'message': sdkerr.message,
    };
  }

  sdkerr.result = clean(ctx, result);
  sdkerr.spec = clean(ctx, spec);

  // Promote the HTTP status to the top level, so a consumer can branch on
  // `err.status` / `err.notFound` instead of reaching into `err.result`.
  sdkerr.status = null == result.status ? -1 : result.status;

  ctx.ctrl['err'] = sdkerr;

  // Fire PreUnexpected so observability features (metrics, telemetry, audit,
  // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
  // rbac short-circuit). Fires after ctx.ctrl['err'] is set so hooks can read
  // the error; features guard against double-recording when PreDone fired.
  final utility = ctx.utility;
  if (null != utility && null != utility.featureHook) {
    utility.featureHook(ctx, 'PreUnexpected');
  }

  // TODO: model option to return instead
  if (false == ctx.ctrl['throw']) {
    return result.resdata;
  } else {
    throw sdkerr;
  }
}
