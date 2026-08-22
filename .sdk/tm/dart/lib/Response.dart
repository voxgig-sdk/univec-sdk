import 'dart:async';

import 'utility/voxgig_struct.dart' as vs;

class Response {
  dynamic status;
  dynamic statusText;
  dynamic headers;
  dynamic jsonFn;
  dynamic err;
  dynamic body;

  Response(dynamic resmap) {
    status = vs.getprop(resmap, 'status', -1);
    statusText = vs.getprop(resmap, 'statusText', '');
    headers = vs.getprop(resmap, 'headers');
    jsonFn = vs.getprop(resmap, 'json');
    body = vs.getprop(resmap, 'body');
    err = vs.getprop(resmap, 'err');
  }

  Future<dynamic> json() async =>
      null == jsonFn ? null : await Future.value(jsonFn());

  Map<String, dynamic> toJSON() => {
        'status': status,
        'statusText': statusText,
        'headers': headers,
        'body': body,
        'err': err,
      };
}
