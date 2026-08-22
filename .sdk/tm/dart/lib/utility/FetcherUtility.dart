import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'voxgig_struct.dart' as vs;

// Make HTTP call using dart:io. Replace this utility for mocking etc.
Future<dynamic> fetcher(dynamic ctx, dynamic fullurl, dynamic fetchdef) async {
  if ('live' != ctx.client.mode) {
    return ctx.error(
        'fetch_mode_block',
        'Request blocked by mode: "' +
            ctx.client.mode.toString() +
            '" (URL was: "' +
            fullurl.toString() +
            '")');
  }

  final options = ctx.client.options();

  if (true == vs.getpath(options, 'feature.test.active')) {
    return ctx.error(
        'fetch_test_block',
        'Request blocked as test feature is active' +
            ' (URL was: "' +
            fullurl.toString() +
            '")');
  }

  final fetch = vs.getpath(options, 'system.fetch') ?? httpFetch;

  final response = await Future.value(fetch(fullurl, fetchdef));

  return response;
}

// Default live transport over dart:io HttpClient. Returns a transport-shaped
// map: { status, statusText, headers, body, json } — the same shape as the
// test feature's mock, so the result pipeline treats both identically.
Future<dynamic> httpFetch(dynamic fullurl, dynamic fetchdef) async {
  final client = HttpClient();
  try {
    final uri = Uri.parse(fullurl.toString());
    final method =
        (vs.getprop(fetchdef, 'method', 'GET') ?? 'GET').toString();

    final req = await client.openUrl(method, uri);

    // Manual redirects: fetchdef['redirect'] == 'manual' surfaces a 3xx as
    // an ordinary response instead of auto-following it — HttpClient would
    // otherwise replay the request, headers included, against whatever host
    // Location names. Set by the station feature's transport middleware
    // under an egress hosts policy (mirrors the ts fetch option).
    if ('manual' == vs.getprop(fetchdef, 'redirect')) {
      req.followRedirects = false;
    }

    final headers = vs.getprop(fetchdef, 'headers');
    if (headers is Map) {
      headers.forEach((k, v) {
        if (null != v) {
          req.headers.set(k.toString(), v.toString());
        }
      });
    }

    final body = vs.getprop(fetchdef, 'body');
    if (null != body) {
      if (null == req.headers.value('content-type')) {
        req.headers.set('content-type', 'application/json');
      }
      req.write(body.toString());
    }

    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();

    final hmap = <String, dynamic>{};
    res.headers.forEach((name, values) {
      hmap[name.toLowerCase()] = values.join(', ');
    });

    dynamic jsonBody() {
      if ('' == text) {
        return null;
      }
      try {
        return jsonDecode(text);
      } catch (_e) {
        return null;
      }
    }

    return {
      'status': res.statusCode,
      'statusText': res.reasonPhrase,
      'headers': hmap,
      'body': '' == text ? null : text,
      'json': jsonBody,
    };
  } finally {
    client.close(force: true);
  }
}
