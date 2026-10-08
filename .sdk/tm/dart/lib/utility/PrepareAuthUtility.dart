import 'dart:convert';

import 'voxgig_struct.dart' as vs;

const HEADER_auth = 'authorization';

const OPTION_apikey = 'apikey';
const OPTION_secret = 'secret';

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

  // True HTTP Basic Auth joins the two credentials, base64-encoded; a single
  // token can never authenticate against an API that checks
  // `Authorization: Basic base64(user:pass)`. The password may be empty
  // (RFC 7617).
  if (true == vs.getpath(options, 'auth.basic')) {
    final secret = vs.getprop(options, OPTION_secret, NOTFOUND);
    final noApikey = NOTFOUND == apikey || null == apikey || '' == apikey;
    final pass = (NOTFOUND == secret || null == secret) ? '' : secret.toString();

    if (noApikey) {
      vs.delprop(headers, HEADER_auth);
    } else {
      final b64 = base64Encode(utf8.encode(apikey.toString() + ':' + pass));
      // The joined, encoded pair is a wire form neither credential's own
      // registration covers.
      ctx.utility.cleanAdd(ctx, b64);
      vs.setprop(
          headers,
          HEADER_auth,
          (null != prefix && '' != prefix)
              ? prefix.toString() + ' ' + b64
              : b64);
    }

    return spec;
  }

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
