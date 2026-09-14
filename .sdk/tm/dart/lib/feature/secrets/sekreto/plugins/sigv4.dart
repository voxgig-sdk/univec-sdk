// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/sigv4.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Signature Version 4, hand-rolled.
//
// A PLUGIN FILE, with `crypto.dart` beside it: the core of no port imports
// a hash function, and this is where sekreto's one use of one lives. Only
// the aws plugin reaches it, and only a consumer that passed the aws plugin
// reaches that.
//
// The AWS providers need exactly one thing from the AWS SDK - request
// signing - and taking the SDK for it would break the no-dependency rule
// that keeps the ports honest. SigV4 is a stable, published algorithm built
// from HMAC-SHA256, which `crypto.dart` supplies.
//
// `sigv4` is pure: the caller passes the timestamp, so the same input
// yields the same signature everywhere. That is what lets the shared spec
// carry known-answer cases that all ports must reproduce bit-for-bit, and
// lets the integration mock recompute the signature server-side.
//
// A port of typescript/plugins/sigv4.ts, which is canonical.

import 'dart:convert';

import '../src/addr.dart';

import 'crypto.dart';
// `uriescape` and `uridecode` live with the transport rather than here, so
// that a plugin which only has to escape a query parameter does not compile
// a hash function to get one. Canonical keeps them in this file because
// JavaScript's own `encodeURIComponent` covers the other plugins' needs and
// dart's `Uri.encodeComponent` does not: it leaves `!*'()` unescaped, which
// is not RFC 3986 and not what AWS signs.
import 'httpjson.dart';

/// One request to sign - the same declarative shape the shared spec uses.
/// `datetime` is `YYYYMMDDTHHMMSSZ`, and it is the caller's, so that signing
/// is a pure function of its input.
class Signing {
  final String method;
  final String url;
  final String service;
  final String region;
  final String keyid;
  final String secret;
  final String datetime;
  final Map<String, String> headers;
  final String body;
  final String? session;

  const Signing({
    required this.method,
    required this.url,
    required this.service,
    required this.region,
    required this.keyid,
    required this.secret,
    required this.datetime,
    this.headers = const {},
    this.body = '',
    this.session,
  });
}

/// The three pieces of a URL that signing needs, split by hand.
///
/// Not `Uri.parse`: the `host` header AWS signs is the WHATWG one - the
/// hostname lowercased, userinfo stripped, and the port present only when
/// it is not the scheme's default - and no platform URL type answers
/// exactly that. A signature over a host the service computes differently
/// is refused with no useful diagnostic.
class _Parts {
  final String host;
  final String path;
  final String query;
  const _Parts(this.host, this.path, this.query);
}

_Parts _split(String url) {
  final mark = url.indexOf('://');
  final scheme = -1 == mark ? '' : url.substring(0, mark).toLowerCase();
  final rest = -1 == mark ? url : url.substring(mark + 3);

  final stop = stopat(rest, '/?#');
  var authority = -1 == stop ? rest : rest.substring(0, stop);
  var tail = -1 == stop ? '' : rest.substring(stop);

  // Userinfo is not part of the signed host.
  final at = authority.lastIndexOf('@');
  if (-1 != at) {
    authority = authority.substring(at + 1);
  }

  String host;
  var port = '';

  if (authority.startsWith('[')) {
    // An IPv6 literal keeps its brackets and carries colons of its own.
    final close = authority.indexOf(']');
    if (-1 == close) {
      host = authority;
    } else {
      host = authority.substring(0, close + 1);
      final after = authority.substring(close + 1);
      if (after.startsWith(':')) {
        port = after.substring(1);
      }
    }
  } else {
    final colon = authority.lastIndexOf(':');
    if (-1 == colon) {
      host = authority;
    } else {
      host = authority.substring(0, colon);
      port = authority.substring(colon + 1);
    }
  }

  host = host.toLowerCase();

  // A default port is implicit, and signing it would not match what the
  // service reconstructs from the request line.
  if (port.isNotEmpty &&
      !('https' == scheme && '443' == port) &&
      !('http' == scheme && '80' == port)) {
    host = '$host:$port';
  }

  final hash = tail.indexOf('#');
  if (-1 != hash) {
    tail = tail.substring(0, hash);
  }

  final mark2 = tail.indexOf('?');
  final path = -1 == mark2 ? tail : tail.substring(0, mark2);
  final query = -1 == mark2 ? '' : tail.substring(mark2 + 1);

  return _Parts(host, path.isEmpty ? '/' : path, query);
}

/// The canonical query string: each pair RFC 3986-escaped, sorted by escaped
/// key then escaped value.
String canonicalquery(String query) {
  if (query.isEmpty) {
    return '';
  }

  final pairs = <List<String>>[];

  for (final pair in query.split('&')) {
    final eq = pair.indexOf('=');
    final key = -1 == eq ? pair : pair.substring(0, eq);
    final value = -1 == eq ? '' : pair.substring(eq + 1);
    pairs.add([uriescape(uridecode(key)), uriescape(uridecode(value))]);
  }

  pairs.sort((left, right) {
    final bykey = left[0].compareTo(right[0]);
    return 0 != bykey ? bykey : left[1].compareTo(right[1]);
  });

  return pairs.map((pair) => '${pair[0]}=${pair[1]}').join('&');
}

/// Sign one request. Returns the headers to attach: authorization,
/// x-amz-date, and x-amz-security-token when a session token was given, in
/// that order - the spec compares the result as a JSON object, and callers
/// print it field by field.
Map<String, String> sigv4(Signing input) {
  final parts = _split(input.url);
  final date = input.datetime.substring(0, 8);
  final session =
      (null == input.session || input.session!.isEmpty) ? null : input.session;

  // Every header that will be signed: the caller's extras, plus host and
  // x-amz-date (and the session token when present), lower-cased and
  // trimmed the way the canonical form requires.
  //
  // Canonical header values are trimmed AND internally collapsed - AWS
  // folds every run of whitespace, tabs included, to one space before
  // signing, so a header like "a  b" must sign as "a b" or the service
  // refuses it.
  final headers = <String, String>{};

  input.headers.forEach((key, value) {
    headers[key.toLowerCase()] = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  });

  // Inserted after the caller's, so they win.
  headers['host'] = parts.host;
  headers['x-amz-date'] = input.datetime;
  if (null != session) {
    headers['x-amz-security-token'] = session;
  }

  final names = headers.keys.toList()..sort();
  final canonicalheaders =
      names.map((name) => '$name:${headers[name]}\n').join();
  final signedheaders = names.join(';');

  final canonicalrequest = [
    input.method.toUpperCase(),
    parts.path,
    canonicalquery(parts.query),
    canonicalheaders,
    signedheaders,
    sha256hex(input.body),
  ].join('\n');

  final scope = '$date/${input.region}/${input.service}/aws4_request';

  final stringtosign = [
    'AWS4-HMAC-SHA256',
    input.datetime,
    scope,
    sha256hex(canonicalrequest),
  ].join('\n');

  final kdate = hmacsha256(utf8.encode('AWS4${input.secret}'), utf8.encode(date));
  final kregion = hmacsha256(kdate, utf8.encode(input.region));
  final kservice = hmacsha256(kregion, utf8.encode(input.service));
  final ksigning = hmacsha256(kservice, utf8.encode('aws4_request'));
  final signature = hex(hmacsha256(ksigning, utf8.encode(stringtosign)));

  final out = <String, String>{};

  out['authorization'] = 'AWS4-HMAC-SHA256 Credential=${input.keyid}/$scope'
      ', SignedHeaders=$signedheaders'
      ', Signature=$signature';
  out['x-amz-date'] = input.datetime;

  if (null != session) {
    out['x-amz-security-token'] = session;
  }

  return out;
}
