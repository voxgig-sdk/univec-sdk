// Update operation fragment: the eject region is spliced into the entity
// class by EntityOperation_dart, with the hook markers expanded.

// EJECT-START

  /// Update a EntityName (see EntityNameUpdateData in
  /// ProjectNameTypes.dart). Returns the entity data map (EntityName).
  Future<dynamic> update([dynamic reqdata, dynamic ctrl]) async {
    final utility = this.utility;

    final makeContext = utility.makeContext;
    final done = utility.done;
    final error = utility.makeError;
    final featureHook = utility.featureHook;
    final makePoint = utility.makePoint;
    final makeRequest = utility.makeRequest;
    final makeResponse = utility.makeResponse;
    final makeResult = utility.makeResult;
    final makeSpec = utility.makeSpec;

    dynamic fres;

    final ctx = makeContext({
      'opname': 'update',
      'ctrl': ctrl ?? {},
      'match': matchVal,
      'data': dataVal,
      'reqdata': reqdata ?? {},
    }, entctx);

    try {
      // #PrePoint-Hook

      ctx.out['point'] = makePoint(ctx);
      if (iserr(ctx.out['point'])) {
        return error(ctx, ctx.out['point']);
      }

      // #PreSpec-Hook

      ctx.out['spec'] = makeSpec(ctx);
      if (iserr(ctx.out['spec'])) {
        return error(ctx, ctx.out['spec']);
      }

      // #PreRequest-Hook

      ctx.out['request'] = await makeRequest(ctx);
      if (iserr(ctx.out['request'])) {
        return error(ctx, ctx.out['request']);
      }

      // #PreResponse-Hook

      ctx.out['response'] = await makeResponse(ctx);
      if (iserr(ctx.out['response'])) {
        return error(ctx, ctx.out['response']);
      }

      // #PreResult-Hook

      ctx.out['result'] = makeResult(ctx);
      if (iserr(ctx.out['result'])) {
        return error(ctx, ctx.out['result']);
      }

      // #PreDone-Hook

      if (null != ctx.result) {
        if (null != ctx.result.resmatch) {
          matchVal = ctx.result.resmatch;
        }

        if (null != ctx.result.resdata) {
          dataVal = ctx.result.resdata;
        }
      }

      final out = done(ctx);

      // An operation resolves to the ENTITY, not the raw data — the record
      // has just been absorbed into this instance and is reached through
      // data(). `done` still runs: it completes the pipeline and raises on
      // failure, and when throwing is disabled it hands back the error
      // payload, which passes through unchanged. See AGENTS.md "Entity
      // operations return ENTITIES".
      return (null != ctx.result && true == ctx.result.ok) ? this : out;
    } catch (err) {
      // #PreUnexpected-Hook

      final uerr = unexpected(ctx, err);

      if (null != uerr) {
        throw uerr;
      } else {
        // Off-happy-path (throw disabled).
        return null;
      }
    }
  }

// EJECT-END
