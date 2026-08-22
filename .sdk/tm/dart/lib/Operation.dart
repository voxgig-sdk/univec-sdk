import 'utility/voxgig_struct.dart' as vs;

import 'Point.dart';

class Operation {
  dynamic entity;
  dynamic name;
  dynamic input;
  List<dynamic> points = [];

  Operation(dynamic opmap) {
    entity = vs.getprop(opmap, 'entity', '_');
    name = vs.getprop(opmap, 'name', '_');
    input = vs.getprop(opmap, 'input', '_');

    final rawpoints = vs.getprop(opmap, 'points', []);
    points = [];
    if (rawpoints is List) {
      for (final p in rawpoints) {
        points.add(p is Point ? p : Point(p));
      }
    }
  }

  Map<String, dynamic> toJSON() => {
        'entity': entity,
        'name': name,
        'input': input,
        'points': points,
      };
}
