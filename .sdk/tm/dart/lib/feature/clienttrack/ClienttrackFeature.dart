// ignore_for_file: non_constant_identifier_names

import 'dart:math';

import '../base/BaseFeature.dart';

// Client tracking. Establishes a stable per-client session id at
// construction and stamps identifying headers on every request: a
// `User-Agent`, an `X-Client-Id` (session), and a fresh per-request
// `X-Request-Id`. This lets a server correlate all traffic from one SDK
// instance and each individual call. Header names, client name/version and
// the id generator are configurable; the session id and request counter are
// exposed on the client track (`clienttrack`).
class ClienttrackFeature extends BaseFeature {
  dynamic _client;
  String _session = '';
  int _requests = 0;

  ClienttrackFeature() {
    version = '0.0.1';
    name = 'clienttrack';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];
    _requests = 0;
    return null;
  }

  @override
  dynamic PostConstruct(dynamic ctx) {
    _session = (options['sessionId'] ?? _genid('session')).toString();
    _client.track['clienttrack'] = <String, dynamic>{
      'session': _session,
      'requests': 0,
      'clientName': _name(),
    };
    return null;
  }

  @override
  dynamic PreRequest(dynamic ctx) {
    final spec = ctx.spec;
    if (null == spec) {
      return null;
    }
    spec.headers ??= {};
    if ('' == _session) {
      _session = (options['sessionId'] ?? _genid('session')).toString();
    }

    final h = options['headers'] ?? {};
    _requests++;
    final requestId = _genid('request');

    _set(spec.headers, (h['agent'] ?? 'User-Agent').toString(), _name());
    _set(spec.headers, (h['client'] ?? 'X-Client-Id').toString(), _session);
    spec.headers[h['request'] ?? 'X-Request-Id'] = requestId;

    final track = _client.track;
    if (null == track['clienttrack']) {
      track['clienttrack'] = <String, dynamic>{
        'session': _session,
        'requests': 0,
        'clientName': _name(),
      };
    }
    track['clienttrack']['requests'] = _requests;
    track['clienttrack']['lastRequestId'] = requestId;
    return null;
  }

  // Do not clobber a caller-provided value (e.g. a custom User-Agent).
  void _set(dynamic headers, String name, String value) {
    final lower = name.toLowerCase();
    for (final k in (headers as Map).keys) {
      if (k.toString().toLowerCase() == lower) {
        return;
      }
    }
    headers[name] = value;
  }

  String _name() {
    final name = options['clientName'] ?? 'Univec-SDK';
    final version = options['clientVersion'] ?? '0.0.1';
    return name.toString() + '/' + version.toString();
  }

  String _genid(String kind) {
    final idgen = options['idgen'];
    if (idgen is Function) {
      return idgen(kind).toString();
    }
    final rng = Random();
    final h = () => rng.nextInt(0x8000000).toRadixString(16);
    final id = kind.substring(0, 1) + '-' + h() + h() + h();
    return id.length > 20 ? id.substring(0, 20) : id;
  }
}
