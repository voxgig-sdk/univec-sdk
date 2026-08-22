import 'dart:async';

Future<dynamic> resultBody(dynamic ctx) async {
  final response = ctx.response;
  final result = ctx.result;

  if (null != result) {
    if (null != response && null != response.jsonFn && null != response.body) {
      final json = await response.json();
      result.body = json;
    }
  }

  return result;
}
