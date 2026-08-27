// ignore_for_file: non_constant_identifier_names

import '../base/BaseFeature.dart';

// Distributed-tracing telemetry. Opens a span per operation (PrePoint),
// propagates trace context to the server as W3C `traceparent` plus
// `X-Trace-Id` / `X-Span-Id` headers (PreRequest), and closes the span on
// completion (PreDone) or failure (PreUnexpected). Finished spans are kept
// on the client track (`telemetry.spans`); an `exporter` callback, when
// provided, is invoked with each finished span. Trace/span id generation
// and the clock are injectable for deterministic tests.
class TelemetryFeature extends BaseFeature {
  dynamic _client;
  final Map<dynamic, dynamic> _spans = {};
  int _seq = 0;

  TelemetryFeature() {
    version = '0.0.1';
    name = 'telemetry';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];
    _spans.clear();
    _seq = 0;

    final track = _client.track;
    if (null == track['telemetry']) {
      track['telemetry'] = <String, dynamic>{'spans': <dynamic>[], 'active': 0};
    }
    return null;
  }

  @override
  dynamic PrePoint(dynamic ctx) {
    final span = <String, dynamic>{
      'traceId': _id('trace'),
      'spanId': _id('span'),
      'name': (null == ctx.op ? '_' : (ctx.op.entity ?? '_')).toString() +
          '.' +
          (null == ctx.op ? '_' : (ctx.op.name ?? '_')).toString(),
      'start': _now(),
      'end': null,
      'durationMs': null,
      'ok': null,
    };
    _spans[ctx] = span;
    _client.track['telemetry']['active']++;
    return null;
  }

  @override
  dynamic PreRequest(dynamic ctx) {
    final span = _spans[ctx];
    final spec = ctx.spec;
    if (null == span || null == spec) {
      return null;
    }
    spec.headers ??= {};
    final h = options['headers'] ?? {};
    spec.headers[h['trace'] ?? 'X-Trace-Id'] = span['traceId'];
    spec.headers[h['span'] ?? 'X-Span-Id'] = span['spanId'];
    spec.headers[h['parent'] ?? 'traceparent'] = '00-' +
        span['traceId'].toString() +
        '-' +
        span['spanId'].toString() +
        '-01';
    return null;
  }

  @override
  dynamic PreDone(dynamic ctx) {
    _close(
        ctx,
        null != ctx.result &&
            false != ctx.result.ok &&
            null == ctx.result.err);
    return null;
  }

  @override
  dynamic PreUnexpected(dynamic ctx) {
    _close(ctx, false);
    return null;
  }

  void _close(dynamic ctx, bool ok) {
    // Close once per operation; a PreDone followed by a pipeline throw
    // (non-2xx) fires PreUnexpected too, which then finds no open span.
    final span = _spans[ctx];
    if (null == span) {
      return;
    }
    _spans.remove(ctx);
    span['end'] = _now();
    final dur = span['end'] - span['start'];
    span['durationMs'] = dur < 0 ? 0 : dur;
    span['ok'] = ok;

    final telemetry = _client.track['telemetry'];
    telemetry['active']--;
    telemetry['spans'].add(span);

    final exporter = options['exporter'];
    if (exporter is Function) {
      try {
        exporter(span);
      } catch (_e) {
        // Exporter failures are swallowed.
      }
    }
  }

  String _id(String kind) {
    final idgen = options['idgen'];
    if (idgen is Function) {
      return idgen(kind).toString();
    }
    // Deterministic-ish sequential id; unique within a client instance.
    _seq++;
    final n = _seq.toRadixString(16).padLeft(4, '0');
    return ('trace' == kind ? 't' : 's') + n.padRight(16, '0');
  }

  num _now() {
    final now = options['now'];
    if (now is Function) {
      return now();
    }
    return DateTime.now().millisecondsSinceEpoch;
  }
}
