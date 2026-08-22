import 'voxgig_struct.dart' as vs;

dynamic prepareMethod(dynamic ctx) {
  final op = ctx.op;
  final opname = op.name;

  final methodMap = {
    'create': 'POST',
    'update': 'PUT',
    'load': 'GET',
    'list': 'GET',
    'remove': 'DELETE',
    'patch': 'PATCH',
  };

  // The API definition is authoritative: a POST-only or PATCH-based API
  // exposes `update` as POST or PATCH, not the PUT the op name implies.
  // Only fall back to the op-name convention when the point has no method.
  // Read the field off the Point object directly: vs.getprop only handles
  // maps and lists, so going through it always missed the point's method and
  // fell back to the op-name convention below. A GraphQL point synthesizes
  // POST for every op, and a POST-only or PATCH-based REST API states its own
  // method too — both were being overridden.
  final method = ctx.point?.method;
  if (method is String && '' != method) {
    return method.toUpperCase();
  }

  return methodMap[opname];
}
