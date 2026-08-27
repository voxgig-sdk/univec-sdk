// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import '../../utility/ErrUtility.dart';

import '../base/BaseFeature.dart';

// Per-request timeout. Wraps the active transport and races each attempt
// against a deadline; if the deadline wins, the request resolves to a
// timeout error instead of hanging. The timer (`setTimer`/`clearTimer`)
// is injectable so tests can drive the deadline deterministically; the
// losing transport future is swallowed once the race is settled.
class TimeoutFeature extends BaseFeature {
  dynamic _client;

  TimeoutFeature() {
    version = '0.0.1';
    name = 'timeout';
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
      return self._withTimeout(ctx2, url, fetchdef, inner);
    };
    return null;
  }

  Future<dynamic> _withTimeout(
      dynamic ctx, dynamic url, dynamic fetchdef, dynamic inner) async {
    final ms =
        null == options['ms'] ? 30000 : (options['ms'] as num).toInt();
    if (0 >= ms) {
      return Future.value(inner(ctx, url, fetchdef));
    }

    final completer = Completer<dynamic>();

    dynamic timer;
    fire() {
      if (!completer.isCompleted) {
        completer.complete(ctx.error(
            'timeout', 'Request exceeded timeout of ' + ms.toString() + 'ms'));
      }
    }

    final schedule = options['setTimer'];
    if (schedule is Function) {
      timer = schedule(fire, ms);
    } else {
      timer = Timer(Duration(milliseconds: ms), fire);
    }

    Future.sync(() => inner(ctx, url, fetchdef)).then((res) {
      if (!completer.isCompleted) {
        completer.complete(res);
      }
    }, onError: (err, st) {
      if (!completer.isCompleted) {
        completer.completeError(err, st);
      }
      // Late transport failures after the deadline are swallowed.
    });

    try {
      final res = await completer.future;

      if (iserr(res) && 'timeout' == errcode(res)) {
        _track(ctx, ms);
      }

      return res;
    } finally {
      final clear = options['clearTimer'];
      if (clear is Function) {
        clear(timer);
      } else if (timer is Timer) {
        timer.cancel();
      }
    }
  }

  void _track(dynamic ctx, int ms) {
    final track = _client.track;
    if (null == track['timeout']) {
      track['timeout'] = <String, dynamic>{'count': 0, 'ms': ms};
    }
    track['timeout']['count']++;
  }
}
