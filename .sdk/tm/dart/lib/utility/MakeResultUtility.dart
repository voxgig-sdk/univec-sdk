dynamic makeResult(dynamic ctx) {
  // PreResult feature hook has already provided a result.
  if (null != ctx.out['result']) {
    return ctx.out['result'];
  }

  final utility = ctx.utility;
  final transformResponse = utility.transformResponse;

  final op = ctx.op;
  final entity = ctx.entity;

  final spec = ctx.spec;
  final result = ctx.result;

  if (null == spec) {
    return ctx.error(
        'result_no_spec', 'Expected context spec property to be defined.');
  }

  if (null == result) {
    return ctx.error(
        'result_no_result', 'Expected context result property to be defined.');
  }

  spec.step = 'result';

  transformResponse(ctx);

  if ('list' == op.name) {
    final resdata = result.resdata;
    result.resdata = [];

    if (resdata is List && 0 < resdata.length) {
      for (final entry in resdata) {
        final ent = entity.make();
        ent.data(entry);
        result.resdata.add(ent);
      }
    }
  }

  if (null != ctx.ctrl['explain']) {
    ctx.ctrl['explain']['result'] = result;
  }

  // NOTE: returns processed result.
  return result;
}
