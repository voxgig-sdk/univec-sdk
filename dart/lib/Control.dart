import 'utility/voxgig_struct.dart' as vs;

// The operation pipeline passes ctrl as a plain map (see Context.ctrl);
// this class documents the recognised control keys.
class Control {
  dynamic throwErr;
  dynamic err;
  dynamic explain;

  Control(dynamic ctrlmap) {
    throwErr = vs.getprop(ctrlmap, 'throw');
    err = vs.getprop(ctrlmap, 'err');
    explain = vs.getprop(ctrlmap, 'explain');
  }
}
