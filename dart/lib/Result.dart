import 'utility/voxgig_struct.dart' as vs;

class Result {
  dynamic ok;
  dynamic status;
  dynamic statusText;
  dynamic headers;
  dynamic body;
  dynamic err;
  dynamic resdata;
  dynamic resmatch;

  // Feature extension slots (paging, streaming).
  dynamic paging;
  dynamic streaming;
  dynamic stream;

  Result(dynamic resmap) {
    ok = vs.getprop(resmap, 'ok', false);
    status = vs.getprop(resmap, 'status', -1);
    statusText = vs.getprop(resmap, 'statusText', '');
    headers = vs.getprop(resmap, 'headers', {});
    body = vs.getprop(resmap, 'body');
    err = vs.getprop(resmap, 'err');
    resdata = vs.getprop(resmap, 'resdata');
    resmatch = vs.getprop(resmap, 'resmatch');
  }

  Map<String, dynamic> toJSON() => {
        'ok': ok,
        'status': status,
        'statusText': statusText,
        'headers': headers,
        'body': body,
        'err': err,
        'resdata': resdata,
        'resmatch': resmatch,
      };
}
