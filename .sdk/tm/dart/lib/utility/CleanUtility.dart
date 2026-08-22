// Clean request data by partially hiding sensitive values.
dynamic clean(dynamic ctx, dynamic val) {
  // final options = ctx.options
  // final cleankeyre = options?['__derived__']?['clean']?['keyre']
  // final hintsize = 4

  // NOTE: mirrors the donor (ts) implementation, where the masking pass is
  // currently disabled; the derived clean.keyre is still computed by
  // makeOptions so this can be enabled without an options change.

  return val;
}
