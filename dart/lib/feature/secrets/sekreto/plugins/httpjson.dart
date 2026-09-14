// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/httpjson.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The shared HTTP-JSON transport, and the child-process runner.
//
// PLUGIN-ONLY, and that is the point of the file. A socket, a TLS handshake
// and a forked process are exactly what the core does not have, so the
// bounded, redirect-refusing, proxy-ignoring JSON round-trip every vault
// client here is built on lives under `plugins/` with them. A chain of the
// four built-in kinds never imports it.
//
// A port of typescript/plugins/httpjson.ts, which is canonical.

import 'dart:convert';
import 'dart:io';

import '../src/json.dart';
import '../src/providers.dart';
import '../src/sekreto.dart';

/// How long any single vault round-trip may take before it is treated as
/// unreachable. Ports carry the same bound.
const Duration TIMEOUT = Duration(seconds: 10);

/// How much of a response body will be read before the store is treated as
/// having answered incoherently. Ports carry the same bound.
///
/// Far above anything real - the largest legitimate payload this library
/// fetches is Doppler's whole-config download, measured in kilobytes. A
/// bound is needed because the TIMEOUT is not one: ten seconds on a loopback
/// or datacentre link is gigabytes, and the body is accumulated in memory
/// before it is parsed. This runs on an application's startup path, so the
/// failure is the application never starting.
const int MAXBODY = 8 * 1024 * 1024;

/// A deadline that never arrives: a configured token is never renewed.
const int NEVER = 0x7fffffffffffffff;

/// The first candidate that is set and non-empty, or the empty string.
String first(List<String?> candidates) {
  for (final candidate in candidates) {
    if (null != candidate && candidate.isNotEmpty) {
      return candidate;
    }
  }
  return '';
}

/// Drop one trailing slash.
String trimslash(String text) => dropsuffix(text, '/');

/// A URL without its query string, for a message that must not leak one.
String bare(String url) {
  final mark = url.indexOf('?');
  return -1 == mark ? url : url.substring(0, mark);
}

// --- percent encoding -----------------------------------------------
//
// WITH THE TRANSPORT, not with the signer, and the difference is a plugin
// or two of compiled SHA-256. Every URL this library builds is built by a
// plugin - a Key Vault query, a Doppler config, an Infisical secret path -
// and `sigv4.dart` uses the SAME pair, so a signed query and a fetched one
// escape identically. Keeping them here means the four kinds that only
// need to escape a query parameter import the transport and stop, rather
// than dragging in the AWS signer and its hash function behind it.

/// RFC 3986 escaping, which is stricter than the usual URL encoder: AWS
/// wants everything but unreserved characters escaped, with uppercase hex.
String uriescape(String text) {
  final out = StringBuffer();

  for (final byte in utf8.encode(text)) {
    final ch = byte & 0xff;
    final unreserved = (0x41 <= ch && 0x5a >= ch) ||
        (0x61 <= ch && 0x7a >= ch) ||
        (0x30 <= ch && 0x39 >= ch) ||
        0x2d == ch ||
        0x5f == ch ||
        0x2e == ch ||
        0x7e == ch;

    if (unreserved) {
      out.writeCharCode(ch);
    } else {
      out.write('%');
      out.write(ch.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }

  return out.toString();
}

/// Two hex digits as a byte, or nothing.
int? _hexbyte(String text) {
  var value = 0;

  for (final unit in text.codeUnits) {
    final digit = _HEX.indexOf(String.fromCharCode(unit).toLowerCase());
    if (-1 == digit) {
      return null;
    }
    value = value * 16 + digit;
  }

  return value;
}

const String _HEX = '0123456789abcdef';

/// Percent-decode, and nothing else: `+` stays `+`, as on the wire.
String uridecode(String text) {
  final out = <int>[];
  var index = 0;

  while (index < text.length) {
    var taken = false;

    if ('%' == text[index] && index + 2 < text.length) {
      final code = _hexbyte(text.substring(index + 1, index + 3));
      if (null != code) {
        out.add(code);
        index += 3;
        taken = true;
      }
    }

    if (!taken) {
      // A stray % is kept as-is, the way a browser would.
      out.addAll(utf8.encode(text[index]));
      index += 1;
    }
  }

  return utf8.decode(out, allowMalformed: true);
}

/// What a finished child process left behind.
class Ran {
  final String out;
  final String why;
  final int status;
  const Ran(this.out, this.why, this.status);
}

/// Run a child to completion and collect both its streams.
///
/// `Process.runSync` closes the child's stdin and drains stdout and stderr
/// together. Both matter. A CLI that prompts for a passphrase when its
/// environment variable is absent sees EOF and gives up rather than waiting
/// forever; and draining one stream to EOF before starting on the other
/// would deadlock the moment the child writes more than one pipe buffer
/// (64 KiB on Linux) to stderr - secretspec's box-drawn diagnostics reach
/// that size easily, and nothing here sets a timeout, so that hang would be
/// permanent.
///
/// The argument list is passed as a list, never through a shell, and no
/// secret is ever put on it: the process table is public.
Ran runcmd(List<String> argv, String command, {Map<String, String>? extraenv}) {
  try {
    final result = Process.runSync(
      argv.first,
      argv.sublist(1),
      environment: extraenv,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    return Ran(
      result.stdout as String,
      (result.stderr as String).trim(),
      result.exitCode,
    );
  } on ProcessException catch (err) {
    throw SekretoError('sekreto: cannot run $command: ${err.message}');
  }
}

/// One JSON round-trip's result: the status, and the parsed body.
class Answer {
  final int status;
  final Json? body;
  const Answer(this.status, this.body);
}

// The one HTTP client, built once.
//
// Redirects are never followed: a vault API does not legitimately redirect,
// and a followed redirect would carry X-Vault-Token to the redirect's host
// (and could downgrade https to http), which checkaddr - it only validates
// the configured address - cannot see.
//
// Proxies are ignored. The GCP and Azure metadata endpoints are not
// loopback, and an `http_proxy` in the environment has sent a Vault token in
// the clear before now. Dart's HttpClient does not read the proxy
// environment unless asked; saying so explicitly makes it auditable rather
// than merely true.
HttpClient? _client;

HttpClient http() {
  final existing = _client;
  if (null != existing) {
    return existing;
  }

  // Additive, never a replacement: the platform roots are loaded first and
  // unconditionally, and SEKRETO_CA_BUNDLE adds to them. It fails open and
  // silently - an unreadable file or a certificate the store rejects adds no
  // roots and raises nothing, so a wrong path cannot turn into a refusal
  // that looks like a network fault.
  final context = SecurityContext(withTrustedRoots: true);
  final extra = getenv('SEKRETO_CA_BUNDLE');

  if (null != extra && extra.isNotEmpty) {
    try {
      context.setTrustedCertificates(extra);
    } catch (_) {
      // Fails open by design.
    }
  }

  final client = HttpClient(context: context);
  client.connectionTimeout = TIMEOUT;
  client.findProxy = (uri) => 'DIRECT';

  _client = client;
  return client;
}

Future<(int, String)> _roundtrip(
  String method,
  String url,
  Map<String, String> headers,
  String? body,
) async {
  final request = await http().openUrl(method, Uri.parse(url));

  request.followRedirects = false;

  headers.forEach((key, value) => request.headers.set(key, value));

  if (null == body) {
    request.contentLength = 0;
  } else {
    final bytes = utf8.encode(body);
    request.contentLength = bytes.length;
    request.add(bytes);
  }

  final response = await request.close();

  // One byte over the bound is enough to know it was exceeded. An endless
  // body is a store that could not answer, so this raises rather than
  // returning a miss - the latter would fall through to a weaker store on an
  // attacker's cue.
  final chunks = <int>[];

  await for (final chunk in response) {
    chunks.addAll(chunk);
    if (MAXBODY < chunks.length) {
      throw SekretoError('sekreto: oversized response from ${bare(url)}');
    }
  }

  return (response.statusCode, utf8.decode(chunks, allowMalformed: true));
}

/// One JSON round-trip. Network failure is always an error - an unreachable
/// store is a store that could not answer, never a store that does not hold
/// the secret.
Future<Answer> fetchjson(
  String method,
  String url, {
  Map<String, String> headers = const {},
  String? body,
}) async {
  final int status;
  final String text;

  try {
    final answered = await _roundtrip(method, url, headers, body).timeout(TIMEOUT);
    status = answered.$1;
    text = answered.$2;
  } on SekretoError {
    // The body bound above; already the message it should be.
    rethrow;
  } catch (err) {
    throw SekretoError('sekreto: cannot reach ${bare(url)}: ${why(err)}');
  }

  // A success status promised JSON; a body that does not parse means the
  // store could not answer coherently, and treating it as a miss would fall
  // through to a weaker store. Error statuses may carry any body - they are
  // decided on status alone.
  final parsed = jsonparse(text);
  if (200 == status && null == parsed) {
    throw SekretoError('sekreto: malformed response from ${bare(url)}');
  }

  return Answer(status, parsed);
}

/// When a logged-in token must be renewed, from its expiry in seconds (a
/// JSON number, or a string as Azure IMDS sends it): now + max(seconds - 60,
/// 1). A missing or zero expiry means never renew.
int renewtime(Json? expires) {
  var seconds = 0.0;

  final number = expires.asnum;
  if (null != number) {
    seconds = number;
  } else {
    final text = expires.asstr;
    if (null != text) {
      seconds = double.tryParse(text) ?? 0.0;
    }
  }

  if (seconds.isNaN || 0 >= seconds) {
    return NEVER;
  }

  final lead = seconds - 60 < 1 ? 1.0 : seconds - 60;
  return DateTime.now().millisecondsSinceEpoch + (lead * 1000).toInt();
}

/// Decode standard base64, strictly.
///
/// Nothing is skipped and nothing is guessed: a lenient decoder silently
/// drops bytes outside the alphabet and hands back plausible bytes for a
/// corrupted payload - which then get returned as the secret. Whitespace is
/// stripped first, because the canonical function accepts a payload wrapped
/// across lines; everything else outside the alphabet is a refusal, and a
/// refusal is an error, never a miss.
String? unbase64(String text) {
  final cleaned = text.replaceAll(RegExp(r'\s'), '');

  if (cleaned.isEmpty || 0 != cleaned.length % 4) {
    return null;
  }

  var end = cleaned.length;
  var pad = 0;
  while (0 < end && '=' == cleaned[end - 1] && 2 > pad) {
    end--;
    pad++;
  }

  for (var at = 0; at < end; at++) {
    if (!_B64.contains(cleaned[at])) {
      return null;
    }
  }

  try {
    return utf8.decode(base64.decode(cleaned), allowMalformed: true);
  } catch (_) {
    return null;
  }
}

const String _B64 =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
