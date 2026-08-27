// ignore_for_file: non_constant_identifier_names

import '../base/BaseFeature.dart';

// Statistics capture. Records per-operation counters and latency for every
// call: totals plus a breakdown keyed by `<entity>.<op>`. Timing starts at
// endpoint resolution (PrePoint) and stops when the call returns (PreDone)
// or throws (PreUnexpected). Aggregates live on the client track
// (`metrics`). The clock is injectable (`now`) for deterministic tests.
class MetricsFeature extends BaseFeature {
  dynamic _client;
  final Map<dynamic, dynamic> _starts = {};

  MetricsFeature() {
    version = '0.0.1';
    name = 'metrics';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];
    _starts.clear();

    final track = _client.track;
    if (null == track['metrics']) {
      track['metrics'] = <String, dynamic>{
        'total': <String, dynamic>{'count': 0, 'ok': 0, 'err': 0, 'totalMs': 0, 'maxMs': 0},
        'ops': <String, dynamic>{},
      };
    }
    return null;
  }

  @override
  dynamic PrePoint(dynamic ctx) {
    _starts[ctx] = _now();
    return null;
  }

  @override
  dynamic PreDone(dynamic ctx) {
    // Classify by the actual result: a 4xx/5xx that flows through still
    // reaches PreDone before the pipeline throws.
    _record(
        ctx,
        null != ctx.result &&
            false != ctx.result.ok &&
            null == ctx.result.err);
    return null;
  }

  @override
  dynamic PreUnexpected(dynamic ctx) {
    _record(ctx, false);
    return null;
  }

  void _record(dynamic ctx, bool ok) {
    // Record once per operation. When a non-2xx result reaches PreDone the
    // pipeline then throws, firing PreUnexpected too; the missing start
    // marker makes the second call a no-op.
    if (!_starts.containsKey(ctx)) {
      return;
    }
    final start = _starts[ctx];
    var dur = null == start ? 0 : _now() - start;
    dur = dur < 0 ? 0 : dur;
    _starts.remove(ctx);

    final m = _client.track['metrics'];
    final key = (null == ctx.op ? '_' : (ctx.op.entity ?? '_')).toString() +
        '.' +
        (null == ctx.op ? '_' : (ctx.op.name ?? '_')).toString();

    var op = m['ops'][key];
    if (null == op) {
      op = m['ops'][key] = <String, dynamic>{'count': 0, 'ok': 0, 'err': 0, 'totalMs': 0, 'maxMs': 0};
    }

    _bump(m['total'], ok, dur);
    _bump(op, ok, dur);
  }

  void _bump(dynamic bucket, bool ok, num dur) {
    bucket['count']++;
    bucket[ok ? 'ok' : 'err']++;
    bucket['totalMs'] += dur;
    if (dur > bucket['maxMs']) {
      bucket['maxMs'] = dur;
    }
  }

  num _now() {
    final now = options['now'];
    if (now is Function) {
      return now();
    }
    return DateTime.now().millisecondsSinceEpoch;
  }
}
