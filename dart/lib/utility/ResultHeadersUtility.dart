dynamic resultHeaders(dynamic ctx) {
  final response = ctx.response;
  final result = ctx.result;

  if (null != result) {
    if (null != response && response.headers is Map) {
      final headers = <String, dynamic>{};
      (response.headers as Map).forEach((k, v) {
        headers[k.toString()] = v;
      });
      result.headers = headers;
    } else {
      result.headers = <String, dynamic>{};
    }
  }

  return result;
}
