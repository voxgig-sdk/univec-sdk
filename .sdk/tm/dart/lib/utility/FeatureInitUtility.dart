import 'voxgig_struct.dart' as vs;

void featureInit(dynamic ctx, dynamic f) {
  final fopts =
      vs.getprop(vs.getprop(ctx.options, 'feature'), f.name) ?? {};
  if (true == fopts['active']) {
    f.init(ctx, fopts);
  }
}
