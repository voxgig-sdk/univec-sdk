// List operation fragment: the eject region is spliced into the entity
// class by EntityOperation_dart, with the hook markers expanded.

// EJECT-START

  /// List EntityName entities by match (see EntityNameListMatch in
  /// ProjectNameTypes.dart). Returns a list of EntityName entity instances.
  Future<dynamic> list([dynamic reqmatch, dynamic ctrl]) async {
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
      'opname': 'list',
      'ctrl': ctrl ?? {},
      'match': matchVal,
      'data': dataVal,
      'reqmatch': reqmatch ?? {},
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
      }

      return done(ctx);
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
