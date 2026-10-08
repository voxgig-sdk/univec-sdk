import 'dart:async';

import 'utility/voxgig_struct.dart' as vs;

class Response {
  dynamic status;
  dynamic statusText;
  dynamic headers;
  dynamic jsonFn;
  dynamic err;
  dynamic body;
  // Set by a transport that could not read a non-blank body as JSON.
  bool unreadable = false;

  Response(dynamic resmap) {
    status = vs.getprop(resmap, 'status', -1);
    statusText = vs.getprop(resmap, 'statusText', '');
    headers = vs.getprop(resmap, 'headers');
    jsonFn = vs.getprop(resmap, 'json');
    body = vs.getprop(resmap, 'body');
    err = vs.getprop(resmap, 'err');
    unreadable = true == vs.getprop(resmap, 'unreadable');
  }

  Future<dynamic> json() async =>
      null == jsonFn ? null : await Future.value(jsonFn());

  Map<String, dynamic> toJson() => toJSON();

  Map<String, dynamic> toJSON() => {
        'status': status,
        'statusText': statusText,
        'headers': headers,
        'body': body,
        'err': err,
      };
}
