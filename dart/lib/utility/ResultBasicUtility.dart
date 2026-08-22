import 'ErrUtility.dart';

dynamic resultBasic(dynamic ctx) {
  final response = ctx.response;
  final result = ctx.result;

  if (null != result && null != response) {
    result.status = response.status ?? -1;
    result.statusText = response.statusText ?? 'no-status';

    // TODO: use spec!
    if (result.status is num && 400 <= result.status) {
      final msg = 'request: ' +
          result.status.toString() +
          ': ' +
          result.statusText.toString();
      if (null != result.err) {
        final prevmsg = errmsg(result.err);
        result.err = ctx.error('request_status', prevmsg + ': ' + msg);
      } else {
        result.err = ctx.error('request_status', msg);
      }
    } else if (null != response.err) {
      result.err = response.err;
    }
  }

  return result;
}
