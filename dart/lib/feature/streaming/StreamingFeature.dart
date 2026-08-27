// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import '../base/BaseFeature.dart';

// Streaming result support. For list-style operations it attaches a
// `result.stream()` Stream factory so callers can consume items
// incrementally with `await for (final item in result.stream())` instead of
// materialising the whole list. The stream reads the result's data lazily,
// so it reflects the parsed entities. A `chunkDelay` (ms) simulates
// paced/chunked delivery for offline tests via the injectable `sleep`; a
// `chunkSize` groups items into batches when set.
class StreamingFeature extends BaseFeature {
  dynamic _client;

  StreamingFeature() {
    version = '0.0.1';
    name = 'streaming';
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
  dynamic PreResult(dynamic ctx) {
    if (!_streamable(ctx)) {
      return null;
    }
    final result = ctx.result;
    if (null == result) {
      return null;
    }

    final self = this;
    result.streaming = true;

    result.stream = () {
      return self._iterate(result);
    };

    final track = _client.track;
    if (null == track['streaming']) {
      track['streaming'] = {'opened': 0};
    }
    track['streaming']['opened']++;
    return null;
  }

  Stream<dynamic> _iterate(dynamic result) async* {
    final chunkDelay = (options['chunkDelay'] ?? 0) as num;
    final chunkSize = (options['chunkSize'] ?? 0) as num;

    // Read lazily so downstream result processing is reflected.
    final items = result.resdata is List ? result.resdata as List : [];

    if (0 < chunkSize) {
      for (var i = 0; i < items.length; i += chunkSize.toInt()) {
        if (0 < chunkDelay) {
          await _sleep(chunkDelay.toInt());
        }
        final end = i + chunkSize.toInt();
        yield items.sublist(i, end > items.length ? items.length : end);
      }
      return;
    }

    for (final item in items) {
      if (0 < chunkDelay) {
        await _sleep(chunkDelay.toInt());
      }
      yield item;
    }
  }

  bool _streamable(dynamic ctx) {
    final ops = options['ops'] ?? ['list'];
    return (ops as List).contains(null == ctx.op ? null : ctx.op.name);
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
}
