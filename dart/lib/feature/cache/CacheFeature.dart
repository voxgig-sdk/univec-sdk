// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import '../../utility/ErrUtility.dart';
import '../../utility/voxgig_struct.dart' as vs;

import '../base/BaseFeature.dart';

// Response caching for safe (read) requests. Wraps the active transport and
// serves a fresh cached snapshot instead of hitting the network when the
// same method+URL was fetched within `ttl` ms. Only successful responses to
// cacheable methods (default: GET) are stored, keyed by method+URL. The
// cache is bounded (`max` entries, oldest evicted) and every hit/miss is
// recorded on the client track for inspection. One-shot response bodies are
// normalised on capture so both the current caller and later hits can read
// the JSON body repeatedly.
class CacheFeature extends BaseFeature {
  dynamic _client;
  final Map<String, dynamic> _store = {};

  CacheFeature() {
    version = '0.0.1';
    name = 'cache';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];

    if (!active) {
      return null;
    }

    _store.clear();

    final self = this;
    final utility = ctx.utility;
    final inner = utility.fetcher;

    utility.fetcher = (dynamic ctx2, dynamic url, dynamic fetchdef) async {
      return self._through(ctx2, url, fetchdef, inner);
    };
    return null;
  }

  Future<dynamic> _through(
      dynamic ctx, dynamic url, dynamic fetchdef, dynamic inner) async {
    final method =
        (vs.getprop(fetchdef, 'method', 'GET') ?? 'GET').toString().toUpperCase();
    final methods = options['methods'] ?? ['GET'];

    if (!(methods as List).contains(method)) {
      return inner(ctx, url, fetchdef);
    }

    final key = method + ' ' + url.toString();
    final now = _now();
    final hit = _store[key];

    if (null != hit && hit['expiry'] > now) {
      _track('hit');
      return _replay(hit['snapshot']);
    }

    final res = await Future.value(inner(ctx, url, fetchdef));

    if (_cacheable(res)) {
      final snapshot = await _snapshot(res);
      final ttl = null == options['ttl'] ? 5000 : options['ttl'];
      _evict();
      _store[key] = <String, dynamic>{'expiry': now + ttl, 'snapshot': snapshot};
      _track('miss');
      return _replay(snapshot);
    }

    _track('bypass');
    return res;
  }

  bool _cacheable(dynamic res) {
    if (null == res || iserr(res)) {
      return false;
    }
    final status = vs.getprop(res, 'status');
    return status is num && status >= 200 && status < 300;
  }

  Future<dynamic> _snapshot(dynamic res) async {
    dynamic data;
    final jsonFn = vs.getprop(res, 'json');
    if (jsonFn is Function) {
      try {
        data = await Future.value(jsonFn());
      } catch (_e) {
        data = null;
      }
    }
    final headers = <String, dynamic>{};
    final rh = vs.getprop(res, 'headers');
    if (rh is Map) {
      rh.forEach((k, v) => headers[k.toString()] = v);
    }
    return <String, dynamic>{
      'status': vs.getprop(res, 'status'),
      'statusText': vs.getprop(res, 'statusText'),
      'data': data,
      'headers': headers,
    };
  }

  dynamic _replay(dynamic snapshot) {
    final headers = snapshot['headers'] ?? {};
    final data = snapshot['data'];
    return <String, dynamic>{
      'status': snapshot['status'],
      'statusText': snapshot['statusText'],
      'body': 'not-used',
      'json': () => data,
      'headers': headers,
    };
  }

  void _evict() {
    final max = null == options['max'] ? 256 : (options['max'] as num).toInt();
    while (_store.length >= max) {
      if (_store.isEmpty) {
        break;
      }
      _store.remove(_store.keys.first);
    }
  }

  num _now() {
    final now = options['now'];
    if (now is Function) {
      return now();
    }
    return DateTime.now().millisecondsSinceEpoch;
  }

  void _track(String kind) {
    final track = _client.track;
    if (null == track['cache']) {
      track['cache'] = <String, dynamic>{'hit': 0, 'miss': 0, 'bypass': 0};
    }
    track['cache'][kind]++;
  }
}
