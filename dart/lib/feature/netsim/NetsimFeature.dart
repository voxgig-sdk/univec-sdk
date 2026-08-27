// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import '../../utility/voxgig_struct.dart' as vs;

import '../base/BaseFeature.dart';

// Network behaviour simulation. Wraps the active transport (the live
// dart:io transport or the `test` feature's in-memory mock) and injects
// realistic network conditions so offline unit tests can exercise slowness,
// transient failures, rate limiting and outages deterministically.
//
// Every injection mode is counter-driven (per client instance) so tests
// are reproducible without mocking timers. `failRate` adds optional
// pseudo-random failures via a seeded LCG for coverage-style testing.
class NetsimFeature extends BaseFeature {
  dynamic _client;
  int _calls = 0;
  int _seed = 1;

  NetsimFeature() {
    version = '0.0.1';
    name = 'netsim';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];
    _seed = options['seed'] is num ? (options['seed'] as num).toInt() : 1;
    if (0 == _seed) {
      _seed = 1;
    }
    _calls = 0;

    if (!active) {
      return null;
    }

    final self = this;
    final utility = ctx.utility;
    final inner = utility.fetcher;

    utility.fetcher = (dynamic ctx2, dynamic url, dynamic fetchdef) async {
      return self._simulate(ctx2, url, fetchdef, inner);
    };
    return null;
  }

  Future<dynamic> _simulate(
      dynamic ctx, dynamic url, dynamic fetchdef, dynamic inner) async {
    final opts = options;
    _calls++;
    final call = _calls;

    // Record the simulated conditions for test/debug inspection.
    final applied = <String, dynamic>{};

    // Total outage: every call fails at the transport level.
    if (true == opts['offline']) {
      await _sleep(_pickLatency());
      applied['offline'] = true;
      _track(ctx, applied);
      return ctx.error('netsim_offline',
          'Simulated network offline (URL was: "' + url.toString() + '")');
    }

    // Connection-level errors for the first N calls (e.g. ECONNRESET).
    final errorTimes =
        opts['errorTimes'] is num ? (opts['errorTimes'] as num).toInt() : 0;
    if (call <= errorTimes) {
      await _sleep(_pickLatency());
      applied['error'] = true;
      _track(ctx, applied);
      return ctx.error('netsim_conn',
          'Simulated connection error (call ' + call.toString() + ')');
    }

    // Rate-limit responses (HTTP 429 + Retry-After) for the first N calls.
    final rateLimitTimes = opts['rateLimitTimes'] is num
        ? (opts['rateLimitTimes'] as num).toInt()
        : 0;
    if (call <= rateLimitTimes) {
      await _sleep(_pickLatency());
      applied['rateLimited'] = true;
      _track(ctx, applied);
      return _respond(ctx, 429, null, {
        'statusText': 'Too Many Requests',
        'headers': {
          'retry-after':
              (null == opts['retryAfter'] ? 0 : opts['retryAfter']).toString()
        },
      });
    }

    // Retryable failure status for the first N calls, or every Nth call.
    final failStatus = null == opts['failStatus'] ? 503 : opts['failStatus'];
    final failTimes =
        opts['failTimes'] is num ? (opts['failTimes'] as num).toInt() : 0;
    final failEvery =
        opts['failEvery'] is num ? (opts['failEvery'] as num).toInt() : 0;
    final failRate = opts['failRate'] is num ? opts['failRate'] as num : 0;
    final failByCount = call <= failTimes;
    final failByEvery = 0 < failEvery && 0 == call % failEvery;
    final failByRate = 0 < failRate && _rand() < failRate;
    if (failByCount || failByEvery || failByRate) {
      await _sleep(_pickLatency());
      applied['failStatus'] = failStatus;
      _track(ctx, applied);
      return _respond(ctx, failStatus, null, {'statusText': 'Simulated Failure'});
    }

    // Otherwise: apply latency then delegate to the real transport.
    final latency = _pickLatency();
    applied['latency'] = latency;
    _track(ctx, applied);
    await _sleep(latency);
    return inner(ctx, url, fetchdef);
  }

  // Latency in ms: a fixed number, or a uniform sample from {min,max}.
  int _pickLatency() {
    final l = options['latency'];
    if (null == l) {
      return 0;
    }
    if (l is num) {
      return l < 0 ? 0 : l.toInt();
    }
    final min = l['min'] is num ? (l['min'] as num).toInt() : 0;
    final max = null == l['max'] ? min : (l['max'] as num).toInt();
    if (max <= min) {
      return min;
    }
    return min + (_rand() * (max - min)).floor();
  }

  Future<void> _sleep(int ms) {
    if (0 >= ms) {
      return Future.value();
    }
    final sleeper = options['sleep'];
    if (sleeper is Function) {
      return Future.value(sleeper(ms)).then((_x) {});
    }
    return Future.delayed(Duration(milliseconds: ms));
  }

  // Deterministic 0..1 pseudo-random via a linear congruential generator.
  double _rand() {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed / 0x7fffffff;
  }

  void _track(dynamic ctx, dynamic applied) {
    final track = _client.track;
    if (null == track['netsim']) {
      track['netsim'] = <String, dynamic>{'calls': 0, 'applied': <dynamic>[]};
    }
    track['netsim']['calls']++;
    track['netsim']['applied'].add(applied);
    if (ctx.ctrl is Map && null != ctx.ctrl['explain']) {
      ctx.ctrl['explain']['netsim'] = track['netsim'];
    }
  }

  // Build a transport-shaped response (matching the test feature's mock).
  dynamic _respond(dynamic ctx, dynamic status, [dynamic data, dynamic extra]) {
    final out = vs.merge([
      <String, dynamic>{
        'status': status,
        'statusText': 'OK',
        'json': () => data,
        'body': 'not-used',
      },
      vs.getdef(extra, {}),
    ]);

    out['headers'] = vs.getprop(out, 'headers', {});

    return out;
  }
}
