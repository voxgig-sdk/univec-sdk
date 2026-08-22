import 'voxgig_struct.dart' as vs;

import 'CleanUtility.dart';

dynamic done(dynamic ctx) {
  final error = ctx.utility.makeError;

  if (null != ctx.ctrl['explain']) {
    ctx.ctrl['explain'] = clean(ctx, ctx.ctrl['explain']);
    vs.delprop(ctx.ctrl['explain']['result'], 'err');
  }

  if (null != ctx.result && true == ctx.result.ok) {
    return ctx.result.resdata;
  }

  return error(ctx);
}
