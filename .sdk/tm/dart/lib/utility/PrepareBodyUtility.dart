dynamic prepareBody(dynamic ctx) {
  final op = ctx.op;

  final utility = ctx.utility;
  final error = utility.makeError;
  final transformRequest = utility.transformRequest;

  dynamic body;

  if ('data' == op.input) {
    try {
      body = transformRequest(ctx);
    } catch (err) {
      return error(ctx, err);
    }
  }

  return body;
}
