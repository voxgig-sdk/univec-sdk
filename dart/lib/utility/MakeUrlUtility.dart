import 'voxgig_struct.dart' as vs;

dynamic makeUrl(dynamic ctx) {
  final spec = ctx.spec;
  final result = ctx.result;

  if (null == spec) {
    return ctx.error(
        'url_no_spec', 'Expected context spec property to be defined.');
  }

  if (null == result) {
    return ctx.error(
        'url_no_result', 'Expected context result property to be defined.');
  }

  // TODO: use parts to avoid regexp?
  var url =
      vs.join([spec.base, spec.prefix, spec.path, spec.suffix], '/', true);
  final resmatch = <String, dynamic>{};

  final params = spec.params;

  for (final item in vs.items(params)) {
    final key = item[0];
    final val = item[1];
    if (null != val) {
      url = url.replaceFirst(
          RegExp('\\{' + vs.escre(key) + '\\}'), vs.escurl(val.toString()));
      resmatch[key] = val;
    }
  }

  // A placeholder left in the route would send the request to the wrong route.
  // The base's own placeholders are server variables, resolved with the options.
  final base = (spec.base is String ? spec.base as String : '')
      .replaceFirst(RegExp(r'/+$'), '');
  final String route =
      url.startsWith(base) ? url.substring(base.length) : url;
  final unfilled = RegExp(r'\{[^{}/]+\}')
      .allMatches(route)
      .map((m) => m.group(0))
      .toList();
  if (unfilled.isNotEmpty) {
    return ctx.error(
        'url_param_missing', 'URL path has no value for ' + unfilled.join(', ') + '.');
  }

  // Append query string from spec.query. Entity ops populate this via
  // PrepareQueryUtility from the operation's reqmatch; direct() callers
  // pass it as fetchargs.query.
  var qsep = '?';
  for (final item in vs.items(spec.query)) {
    final key = item[0];
    final val = item[1];
    if (null != val) {
      url = url + qsep + vs.escurl(key) + '=' + vs.escurl(val.toString());
      qsep = '&';
      resmatch[key] = val;
    }
  }

  result.resmatch = resmatch;

  return url;
}
