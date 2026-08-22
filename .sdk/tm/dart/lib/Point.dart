import 'utility/voxgig_struct.dart' as vs;

class Point {
  dynamic args;
  // Transport this point speaks: 'http' (default) or 'graphql'. GraphQL
  // points carry their operation document in `graphql` and address the
  // single endpoint, so method is always POST and parts is empty.
  dynamic kind;
  dynamic graphql;
  dynamic rename;
  dynamic method;
  dynamic orig;
  dynamic parts;
  dynamic params;
  dynamic select;
  dynamic active;
  dynamic relations;
  dynamic alias;
  dynamic transform;

  Point(dynamic altmap) {
    args = vs.getprop(altmap, 'args', {'params': []});
    kind = vs.getprop(altmap, 'kind', 'http');
    graphql = vs.getprop(altmap, 'graphql');
    rename = vs.getprop(altmap, 'rename', {'params': {}});
    method = vs.getprop(altmap, 'method', '');
    orig = vs.getprop(altmap, 'orig', '');
    parts = vs.getprop(altmap, 'parts', []);
    params = vs.getprop(altmap, 'params', []);
    select = vs.getprop(altmap, 'select');
    // Absent in config means ACTIVE: emission drops `active: true` as a default (sdkgen L0), so only an explicit `active: false` turns a point off.
    active = vs.getprop(altmap, 'active', true);
    relations = vs.getprop(altmap, 'relations', []);
    alias = vs.getprop(altmap, 'alias', {});
    transform = vs.getprop(altmap, 'transform', {'req': null, 'res': null});
  }

  Map<String, dynamic> toJSON() => {
        'args': args,
        'rename': rename,
        'method': method,
        'orig': orig,
        'parts': parts,
        'params': params,
        'select': select,
        'active': active,
        'relations': relations,
        'alias': alias,
        'transform': transform,
      };
}
