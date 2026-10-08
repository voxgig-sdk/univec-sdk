import 'voxgig_struct.dart' as vs;

import 'ParamUtility.dart';

// The media types a point declares: `response` (the model's `rs`) for the
// Accept header, and `body` (the model's `rb`) for the request body.

// The data key of a raw request body; like `$action`, never an argument name.
const RAW_BODY = r'$body';

bool isJsonMedia(dynamic type) {
  final media =
      (null == type ? '' : type.toString()).split(';')[0].trim().toLowerCase();
  return 'application/json' == media ||
      'text/json' == media ||
      media.endsWith('+json');
}

// The declared JSON type alone, else every declared type in model order; nothing without a body.
String? acceptOf(dynamic point) {
  final res = pointProp(point, 'response');
  final media = vs.getprop(res, 'media');
  if (media is! String || '' == media) return null;
  if ('json' == vs.getprop(res, 'kind')) return media;
  final all = <String>[media];
  final alts = vs.getprop(res, 'alternatives');
  if (alts is List) {
    for (final alt in alts) {
      final m = vs.getprop(alt, 'media');
      if (m is String && '' != m) all.add(m);
    }
  }
  return all.join(', ');
}

bool isRawRequest(dynamic point) =>
    'raw' == vs.getprop(pointProp(point, 'body'), 'kind');

dynamic rawBody(dynamic reqdata) => reqdata is Map ? reqdata[RAW_BODY] : null;

bool hasHeader(dynamic headers, String name) =>
    (headers as Map).keys.any((key) => name == key.toString().toLowerCase());

// A caller's accept wins. A declared request type replaces each JSON
// content-type, the SDK default, and leaves any other the caller set.
dynamic mediaHeaders(dynamic point, dynamic headers) {
  final accept = acceptOf(point);
  if (null != accept && !hasHeader(headers, 'accept')) {
    headers['accept'] = accept;
  }

  final body = pointProp(point, 'body');
  final kind = vs.getprop(body, 'kind');
  final media = vs.getprop(body, 'media');
  if (('raw' == kind || 'json' == kind) && media is String && '' != media) {
    for (final key in List.from(headers.keys)) {
      if ('content-type' == key.toString().toLowerCase() &&
          isJsonMedia(headers[key])) {
        headers.remove(key);
      }
    }
    if (!hasHeader(headers, 'content-type')) {
      headers['content-type'] = media;
    }
  }

  return headers;
}
