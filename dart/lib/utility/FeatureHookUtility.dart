import 'dart:async';

dynamic featureHook(dynamic ctx, String name) {
  final client = ctx.client;

  final resp = <Future>[];
  final List features = (null == client ? null : client.features) ?? [];

  for (final f in features) {
    final fres = f.invokeHook(name, ctx);
    if (fres is Future) {
      resp.add(fres);
    }
  }

  if (0 < resp.length) {
    return Future.wait(resp);
  }
  return null;
}
