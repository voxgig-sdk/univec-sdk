import 'voxgig_struct.dart' as vs;

import 'CleanUtility.dart';

dynamic done(dynamic ctx) {
  final error = ctx.utility.makeError;

  cleanExplain(ctx);

  if (null != ctx.result && true == ctx.result.ok) {
    return ctx.result.resdata;
  }

  return error(ctx);
}

// In place: the caller may hold the record, and a stream copies only its ctrl.
void cleanExplain(dynamic ctx) {
  final explain = ctx.ctrl['explain'];
  if (explain is! Map) {
    return;
  }
  dynamic record = explain;
  final cleaned = clean(ctx, explain);
  if (!identical(cleaned, explain) && cleaned is Map) {
    try {
      explain.addAll(cleaned);
      explain.removeWhere((k, _) => !cleaned.containsKey(k));
    } on TypeError {
      // A record typed too narrowly to take the cleaned values is swapped out.
      ctx.ctrl['explain'] = record = cleaned;
    }
  }
  // With clean off, result is the live Result, which delprop leaves alone.
  vs.delprop(record['result'], 'err');
}
