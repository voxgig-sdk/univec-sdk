import 'voxgig_struct.dart' as vs;

const HEADER_auth = 'authorization';

const OPTION_apikey = 'apikey';

const NOTFOUND = '__NOTFOUND__';

dynamic prepareAuth(dynamic ctx) {
  final client = ctx.client;
  final spec = ctx.spec;

  if (null == spec) {
    return ctx.error(
        'auth_no_spec', 'Expected context spec property to be defined.');
  }

  final headers = spec.headers;

  final options = client.options();

  // Public APIs that need no auth omit the options.auth block entirely.
  if (null == vs.getprop(options, 'auth')) {
    vs.delprop(headers, HEADER_auth);
    return spec;
  }

  final prefix = vs.getpath(options, 'auth.prefix');

  final apikey = vs.getprop(options, OPTION_apikey, NOTFOUND);

  if (NOTFOUND == apikey || null == apikey || '' == apikey) {
    vs.delprop(headers, HEADER_auth);
  } else {
    // A raw credential (empty prefix, e.g. an apiKey scheme) must go in
    // as-is; only a non-empty prefix (Bearer/Basic/OAuth) is space-joined.
    vs.setprop(
        headers,
        HEADER_auth,
        (null != prefix && '' != prefix)
            ? prefix.toString() + ' ' + apikey.toString()
            : apikey);
  }

  return spec;
}
