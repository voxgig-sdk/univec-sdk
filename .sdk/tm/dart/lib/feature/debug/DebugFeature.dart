// ignore_for_file: non_constant_identifier_names

import '../base/BaseFeature.dart';

// Request/response capture for debugging. Records a bounded ring buffer of
// per-operation traces — method, URL, redacted headers, response status and
// timing — on the client track (`debug.entries`). Sensitive header values
// (matching `redact`, default authorization/cookie/api-key style names) are
// masked. An optional `onEntry` callback receives each finished entry (e.g.
// to stream to a console). `max` caps the buffer (default 100).
class DebugFeature extends BaseFeature {
  dynamic _client;
  final Map<dynamic, dynamic> _entries = {};

  DebugFeature() {
    version = '0.0.1';
    name = 'debug';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];
    _entries.clear();

    final track = _client.track;
    if (null == track['debug']) {
      track['debug'] = <String, dynamic>{'entries': <dynamic>[]};
    }
    return null;
  }

  @override
  dynamic PreRequest(dynamic ctx) {
    final spec = ctx.spec;
    final entry = <String, dynamic>{
      'op': (null == ctx.op ? '_' : (ctx.op.entity ?? '_')).toString() +
          '.' +
          (null == ctx.op ? '_' : (ctx.op.name ?? '_')).toString(),
      'method': null == spec ? null : spec.method,
      'url': null == spec ? null : (spec.url ?? spec.path),
      'headers': _redact(null == spec ? null : spec.headers),
      'start': _now(),
      'status': null,
      'ok': null,
      'durationMs': null,
      'error': null,
    };
    _entries[ctx] = entry;
    return null;
  }

  @override
  dynamic PreResponse(dynamic ctx) {
    final entry = _entries[ctx];
    if (null == entry) {
      return null;
    }
    final response = ctx.response;
    if (null != response) {
      entry['status'] = response.status;
      entry['url'] = entry['url'] ?? (null == ctx.spec ? null : ctx.spec.url);
    }
    return null;
  }

  @override
  dynamic PreDone(dynamic ctx) {
    _finish(ctx, true);
    return null;
  }

  @override
  dynamic PreUnexpected(dynamic ctx) {
    final entry = _entries[ctx];
    if (null != entry && ctx.ctrl is Map) {
      final err = ctx.ctrl['err'];
      if (null != err) {
        try {
          entry['error'] = (err as dynamic).message;
        } catch (_e) {
          entry['error'] = err.toString();
        }
      }
    }
    _finish(ctx, false);
    return null;
  }

  void _finish(dynamic ctx, bool ok) {
    final entry = _entries[ctx];
    if (null == entry) {
      return;
    }
    _entries.remove(ctx);
    entry['ok'] = ok && (null == ctx.result || false != ctx.result.ok);
    var dur = _now() - entry['start'];
    entry['durationMs'] = dur < 0 ? 0 : dur;
    if (null == entry['status'] && null != ctx.result) {
      entry['status'] = ctx.result.status;
    }

    final List buf = _client.track['debug']['entries'];
    buf.add(entry);
    final max = null == options['max'] ? 100 : (options['max'] as num).toInt();
    while (buf.length > max) {
      buf.removeAt(0);
    }

    final onEntry = options['onEntry'];
    if (onEntry is Function) {
      try {
        onEntry(entry);
      } catch (_e) {
        // Callback failures are swallowed.
      }
    }
  }

  dynamic _redact(dynamic headers) {
    if (headers is! Map) {
      return {};
    }
    final patterns = options['redact'] ??
        [
          'authorization',
          'cookie',
          'set-cookie',
          'api-key',
          'apikey',
          'x-api-key',
          'idempotency-key'
        ];
    final out = <String, dynamic>{};
    for (final k in headers.keys) {
      out[k.toString()] =
          (patterns as List).contains(k.toString().toLowerCase())
              ? '<redacted>'
              : headers[k];
    }
    return out;
  }

  num _now() {
    final now = options['now'];
    if (now is Function) {
      return now();
    }
    return DateTime.now().millisecondsSinceEpoch;
  }
}
