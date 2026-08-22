void featureAdd(dynamic ctx, dynamic f) {
  final client = ctx.client;

  final dynamic rawopts = f.options;
  final Map fopts = rawopts is Map ? rawopts : {};
  var added = false;
  final List features = client.features;

  final before = fopts['__before__'];
  final after = fopts['__after__'];
  final repl = fopts['__replace__'];

  if (null != before || null != after || null != repl) {
    for (var i = 0; i < features.length; i++) {
      final ef = features[i];
      if (before == ef.name) {
        features.insert(i, f);
        added = true;
        break;
      } else if (after == ef.name) {
        features.insert(i + 1, f);
        added = true;
        break;
      } else if (repl == ef.name) {
        features[i] = f;
        added = true;
        break;
      }
    }
  }

  if (!added) {
    features.add(f);
  }
}
