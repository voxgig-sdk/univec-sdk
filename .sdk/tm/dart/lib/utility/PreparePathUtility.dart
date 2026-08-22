import 'voxgig_struct.dart' as vs;

dynamic preparePath(dynamic ctx) {
  final point = ctx.point;

  final path = vs.join(point.parts, '/', true);

  return path;
}
