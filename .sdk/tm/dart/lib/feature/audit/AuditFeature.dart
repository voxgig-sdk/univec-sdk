// ignore_for_file: non_constant_identifier_names

import '../base/BaseFeature.dart';

// Audit trail. Emits a structured record for every operation — who (actor),
// what (entity + op), the outcome, and a correlation id — suitable for
// compliance logging. Records accumulate on the client track
// (`audit.records`, bounded by `max`) and, when a `sink` callback is
// supplied, are also pushed to it (e.g. to forward to a SIEM). The actor is
// taken from options (`actor`) or a per-call `ctrl.actor`. Timestamps use
// the injectable `now` clock so tests stay deterministic.
class AuditFeature extends BaseFeature {
  dynamic _client;
  int _seq = 0;
  final Set<dynamic> _seen = {};

  AuditFeature() {
    version = '0.0.1';
    name = 'audit';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];
    _seq = 0;
    _seen.clear();

    final track = _client.track;
    if (null == track['audit']) {
      track['audit'] = <String, dynamic>{'records': <dynamic>[]};
    }
    return null;
  }

  @override
  dynamic PreDone(dynamic ctx) {
    // Outcome reflects the actual result; a non-2xx reaches PreDone before
    // the pipeline throws.
    _emit(
        ctx,
        (null != ctx.result &&
                false != ctx.result.ok &&
                null == ctx.result.err)
            ? 'ok'
            : 'error');
    return null;
  }

  @override
  dynamic PreUnexpected(dynamic ctx) {
    _emit(ctx, 'error');
    return null;
  }

  void _emit(dynamic ctx, String outcome) {
    // One record per operation (PreDone + a following PreUnexpected on a
    // non-2xx must not double-log).
    if (_seen.contains(ctx)) {
      return;
    }
    _seen.add(ctx);
    _seq++;
    final record = <String, dynamic>{
      'seq': _seq,
      'ts': _now(),
      'actor': (ctx.ctrl is Map ? ctx.ctrl['actor'] : null) ??
          options['actor'] ??
          'anonymous',
      'entity': null == ctx.op ? '_' : (ctx.op.entity ?? '_'),
      'op': null == ctx.op ? '_' : (ctx.op.name ?? '_'),
      'outcome': outcome,
      'status': null == ctx.result ? null : ctx.result.status,
      'correlationId': ctx.id,
    };

    final List recs = _client.track['audit']['records'];
    recs.add(record);
    final max = null == options['max'] ? 1000 : (options['max'] as num).toInt();
    while (recs.length > max) {
      recs.removeAt(0);
    }

    final sink = options['sink'];
    if (sink is Function) {
      try {
        sink(record);
      } catch (_e) {
        // Sink failures are swallowed.
      }
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
