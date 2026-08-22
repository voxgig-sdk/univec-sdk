import '../Result.dart';

import 'voxgig_struct.dart' as vs;

import 'ErrUtility.dart';

dynamic makeFetchDef(dynamic ctx) {
  final spec = ctx.spec;
  final utility = ctx.utility;
  final makeUrl = utility.makeUrl;

  if (null == spec) {
    return ctx.error(
        'fetchdef_no_spec', 'Expected context spec property to be defined.');
  }

  if (null == ctx.result) {
    ctx.result = Result({});
  }

  spec.step = 'prepare';

  final url = makeUrl(ctx);
  if (iserr(url)) {
    return url;
  }

  spec.url = url;

  final fetchdef = <String, dynamic>{
    'url': url,
    'method': spec.method,
    'headers': spec.headers,
  };

  if (null != spec.body) {
    fetchdef['body'] =
        vs.isnode(spec.body) ? vs.jsonify(spec.body) : spec.body;
  }

  return fetchdef;
}
