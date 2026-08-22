import '../Context.dart';

dynamic makeContext(dynamic ctxmap, [dynamic basectx]) {
  final ctx = Context(ctxmap, basectx);
  return ctx;
}
