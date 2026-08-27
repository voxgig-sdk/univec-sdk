// ignore_for_file: non_constant_identifier_names

import 'dart:math';

import '../base/BaseFeature.dart';

// Idempotency keys for mutating operations. Adds an `Idempotency-Key`
// header (name configurable) to unsafe requests so a server can
// de-duplicate retried writes. The key is set once, at PreRequest, before
// the request is built — so it is stable across transport-level retries of
// the same call. A caller-supplied header is never overwritten.
class IdempotencyFeature extends BaseFeature {
  dynamic _client;

  IdempotencyFeature() {
    version = '0.0.1';
    name = 'idempotency';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];
    return null;
  }

  @override
  dynamic PreRequest(dynamic ctx) {
    final spec = ctx.spec;
    if (null == spec) {
      return null;
    }

    if (!_mutating(ctx)) {
      return null;
    }

    final header = options['header'] ?? 'Idempotency-Key';
    spec.headers ??= {};

    // Respect a key the caller already provided.
    if (null != _existing(spec.headers, header)) {
      return null;
    }

    final key = _genkey();
    spec.headers[header] = key;

    final track = _client.track;
    if (null == track['idempotency']) {
      track['idempotency'] = <String, dynamic>{'issued': 0, 'last': null};
    }
    track['idempotency']['issued']++;
    track['idempotency']['last'] = key;
    return null;
  }

  bool _mutating(dynamic ctx) {
    final methods = options['methods'] ?? ['POST', 'PUT', 'PATCH', 'DELETE'];
    final method = (null == ctx.spec || null == ctx.spec.method)
        ? ''
        : ctx.spec.method.toString().toUpperCase();
    if ('' != method && (methods as List).contains(method)) {
      return true;
    }
    final opname = null == ctx.op ? null : ctx.op.name;
    final ops = options['ops'] ?? ['create', 'update', 'remove'];
    return (ops as List).contains(opname);
  }

  dynamic _existing(dynamic headers, String header) {
    final lower = header.toLowerCase();
    for (final k in (headers as Map).keys) {
      if (k.toString().toLowerCase() == lower) {
        return headers[k];
      }
    }
    return null;
  }

  String _genkey() {
    final keygen = options['keygen'];
    if (keygen is Function) {
      return keygen().toString();
    }
    final rng = Random();
    final h = () => rng.nextInt(0x8000000).toRadixString(16);
    return (h() + h() + h() + h()).padRight(24, '0').substring(0, 24);
  }
}
