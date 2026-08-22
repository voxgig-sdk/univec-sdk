import 'voxgig_struct.dart' as vs;

dynamic prepareHeaders(dynamic ctx) {
  final client = ctx.client;

  final options = client.options();

  final out = vs.clone(vs.getprop(options, 'headers', {}));

  return out;
}
