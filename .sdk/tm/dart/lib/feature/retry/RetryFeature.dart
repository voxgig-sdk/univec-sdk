// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:math';

import '../../utility/ErrUtility.dart';
import '../../utility/voxgig_struct.dart' as vs;

import '../base/BaseFeature.dart';

// Automatic retry of transient failures with exponential backoff and
// jitter. Wraps the active transport so a single operation call may make
// several HTTP attempts. A failure is retryable when the transport throws
// / returns an error, or responds with a status in `statuses`
// (default: 408, 425, 429, 500, 502, 503, 504). An HTTP 429/503 with a
// `Retry-After` header overrides the computed backoff.
class RetryFeature extends BaseFeature {
  dynamic _client;

  RetryFeature() {
    version = '0.0.1';
    name = 'retry';
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

    final self = this;
    final utility = ctx.utility;
    final inner = utility.fetcher;

    utility.fetcher = (dynamic ctx2, dynamic url, dynamic fetchdef) async {
      return self._withRetry(ctx2, url, fetchdef, inner);
    };
    return null;
  }

  Future<dynamic> _withRetry(
      dynamic ctx, dynamic url, dynamic fetchdef, dynamic inner) async {
    final opts = options;
    final max = null == opts['retries'] ? 2 : (opts['retries'] as num).toInt();
    final minDelay =
        null == opts['minDelay'] ? 50 : (opts['minDelay'] as num).toInt();
    final maxDelay =
        null == opts['maxDelay'] ? 2000 : (opts['maxDelay'] as num).toInt();
    final factor = null == opts['factor'] ? 2 : opts['factor'];

    var attempt = 0;

    for (;;) {
      dynamic res;
      var threw = false;
      try {
        res = await Future.value(inner(ctx, url, fetchdef));
      } catch (err) {
        threw = true;
        res = err;
      }

      final retryable = _retryable(res);
      if (!retryable || attempt >= max) {
        // Out of attempts: rethrow a thrown error to preserve pipeline
        // semantics, otherwise return the last response/error.
        if (threw && attempt >= max) {
          throw res;
        }
        return res;
      }

      final wait = _backoff(res, attempt, minDelay, maxDelay, factor);
      _track(ctx, attempt + 1, res, wait);
      await _sleep(wait);
      attempt++;
    }
  }

  bool _retryable(dynamic res) {
    if (null == res) {
      return true;
    }
    if (iserr(res)) {
      return true;
    }
    final status = vs.getprop(res, 'status');
    if (status is! num) {
      return false;
    }
    final statuses =
        options['statuses'] ?? [408, 425, 429, 500, 502, 503, 504];
    return (statuses as List).contains(status);
  }

  int _backoff(
      dynamic res, int attempt, int minDelay, int maxDelay, dynamic factor) {
    // Honour a server-provided Retry-After (seconds) when present.
    final ra = _retryAfter(res);
    if (null != ra) {
      return min(maxDelay, ra);
    }
    final base = minDelay * pow(factor is num ? factor : 2, attempt);
    final jitter = false == options['jitter']
        ? 0
        : Random().nextInt(minDelay < 1 ? 1 : minDelay);
    return min(maxDelay, base.toInt() + jitter);
  }

  int? _retryAfter(dynamic res) {
    if (null == res) {
      return null;
    }
    final headers = vs.getprop(res, 'headers');
    if (headers is! Map) {
      return null;
    }
    final v = headers['retry-after'] ?? headers['Retry-After'];
    if (null == v) {
      return null;
    }
    final n = v is num ? v : num.tryParse(v.toString());
    return null == n ? null : (n * 1000).toInt();
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

  void _track(dynamic ctx, int attempt, dynamic res, int wait) {
    final track = _client.track;
    if (null == track['retry']) {
      track['retry'] = <String, dynamic>{'attempts': 0, 'retries': <dynamic>[]};
    }
    track['retry']['attempts']++;
    track['retry']['retries'].add({
      'attempt': attempt,
      'status': vs.getprop(res, 'status'),
      'error': iserr(res) ? errmsg(res) : null,
      'wait': wait,
    });
  }
}
