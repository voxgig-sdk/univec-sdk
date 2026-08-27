// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import '../base/BaseFeature.dart';

// Client-side rate limiting via a token bucket. Each request consumes a
// token; when the bucket is empty the request waits until the bucket
// refills at `rate` tokens per second (with capacity `burst`). This keeps
// the client under a server's published quota rather than discovering it
// via 429s. The clock (`now`) and the wait (`sleep`) are injectable so the
// accounting can be tested deterministically without wall-clock timing.
class RatelimitFeature extends BaseFeature {
  dynamic _client;
  num _tokens = 0;
  num _last = 0;

  RatelimitFeature() {
    version = '0.0.1';
    name = 'ratelimit';
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

    final burst = null == options['burst']
        ? (options['rate'] ?? 5)
        : options['burst'];
    _tokens = burst is num ? burst : 5;
    _last = _now();

    final self = this;
    final utility = ctx.utility;
    final inner = utility.fetcher;

    utility.fetcher = (dynamic ctx2, dynamic url, dynamic fetchdef) async {
      await self._acquire(ctx2);
      return inner(ctx2, url, fetchdef);
    };
    return null;
  }

  Future<void> _acquire(dynamic ctx) async {
    final rate = (options['rate'] ?? 5) as num;
    final burst = (null == options['burst'] ? rate : options['burst']) as num;

    // Refill according to elapsed time.
    final now = _now();
    final elapsed = now - _last;
    _last = now;
    final refilled = _tokens + (elapsed / 1000) * rate;
    _tokens = refilled < burst ? refilled : burst;

    if (_tokens >= 1) {
      _tokens -= 1;
      return;
    }

    // Not enough tokens: wait for one to accrue, then consume it.
    final needed = 1 - _tokens;
    final waitMs = ((needed / rate) * 1000).ceil();
    _track(ctx, waitMs);
    await _sleep(waitMs);
    _last = _now();
    _tokens = 0;
  }

  num _now() {
    final now = options['now'];
    if (now is Function) {
      return now();
    }
    return DateTime.now().millisecondsSinceEpoch;
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

  void _track(dynamic ctx, int waitMs) {
    final track = _client.track;
    if (null == track['ratelimit']) {
      track['ratelimit'] = <String, dynamic>{'throttled': 0, 'waitMs': 0};
    }
    track['ratelimit']['throttled']++;
    track['ratelimit']['waitMs'] += waitMs;
  }
}
