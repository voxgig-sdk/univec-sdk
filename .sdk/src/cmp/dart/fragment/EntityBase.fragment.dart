
// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import 'utility/ErrUtility.dart';

// Base class for generated entities. `dataVal`/`matchVal` hold accreted
// partial state (they start {} and fill in as ops resolve); the full typed
// data models are documented in ProjectNameTypes.dart.
class ProjectNameEntityBase {
  String name = '';
  String name_ = '';
  String Name = '';

  dynamic client;
  dynamic utility;
  dynamic entoptsMap;
  dynamic dataVal = {};
  dynamic matchVal = {};
  dynamic entctx;

  ProjectNameEntityBase(dynamic client_, dynamic entopts_) {
    final entopts = entopts_ ?? {};
    if (entopts is Map) {
      entopts['active'] = false != entopts['active'];
    }

    client = client_;
    entoptsMap = entopts;
    utility = client_.utility();
    dataVal = {};
    matchVal = {};

    final makeContext = utility.makeContext;

    entctx = makeContext({
      'entity': this,
      'entopts': entopts,
    }, client_.rootctx);

    final featureHook = utility.featureHook;
    featureHook(entctx, 'PostConstructEntity');
  }

  // Every operation resolves to the entity; `remove` additionally marks
  // it. The instance KEEPS the data it held — a caller can still read what
  // was deleted — but it is no longer a live record. See AGENTS.md.
  bool _deleted = false;

  void markDeleted() {
    _deleted = true;
  }

  bool deleted() => _deleted;


  dynamic entopts() {
    return utility.struct.merge([{}, entoptsMap]);
  }

  dynamic data([dynamic d]) {
    final struct = utility.struct;
    final featureHook = utility.featureHook;

    if (null != d) {
      dataVal = struct.clone(d);
      featureHook(entctx, 'SetData');
    }

    featureHook(entctx, 'GetData');
    final out = struct.clone(dataVal);

    return out;
  }

  dynamic match([dynamic m]) {
    final struct = utility.struct;
    final featureHook = utility.featureHook;

    if (null != m) {
      matchVal = struct.clone(m);
      featureHook(entctx, 'SetMatch');
    }

    featureHook(entctx, 'GetMatch');
    final out = struct.clone(matchVal);

    return out;
  }

  // Streaming operation. Runs `action` through the full pipeline and returns
  // a Stream over the result items, so the `streaming` feature's incremental
  // output is reachable from a generated entity (a normal op call
  // materialises the whole result). `callopts` parameterises the call:
  //   - inbound (download): yields items/chunks from the streaming feature
  //     when active, else falls back to the materialised items;
  //   - outbound (upload): an async-iterable/Stream `body` is attached to the
  //     request so the transport can stream a request payload;
  //   - `ctrl` (pipeline control) and `signal` (cancellation) are honoured.
  Stream<dynamic> stream(String action,
      [dynamic args, dynamic callopts]) async* {
    final utility = this.utility;

    final makeContext = utility.makeContext;
    final done = utility.done;
    final featureHook = utility.featureHook;
    final makePoint = utility.makePoint;
    final makeSpec = utility.makeSpec;
    final makeRequest = utility.makeRequest;
    final makeResponse = utility.makeResponse;
    final makeResult = utility.makeResult;

    callopts = callopts ?? {};
    final signal = callopts is Map ? callopts['signal'] : null;

    final ctrl = <String, dynamic>{};
    if (callopts is Map && callopts['ctrl'] is Map) {
      (callopts['ctrl'] as Map).forEach((k, v) => ctrl[k.toString()] = v);
    }
    ctrl['stream'] = callopts;

    final ctxmap = <String, dynamic>{
      'opname': action,
      'ctrl': ctrl,
      'match': matchVal,
      'data': dataVal,
    };
    if (args is Map) {
      args.forEach((k, v) => ctxmap[k.toString()] = v);
    }

    final ctx = makeContext(ctxmap, entctx);

    // Outbound: expose the caller's async-iterable/Stream payload so the
    // request builder / transport can stream it as the request body.
    final body = callopts is Map ? callopts['body'] : null;
    if (null != body) {
      final rd = ctx.reqdata is Map
          ? Map<String, dynamic>.from(ctx.reqdata)
          : <String, dynamic>{};
      rd[r'body$'] = body;
      ctx.reqdata = rd;
      ctrl['stream_out'] = body;
    }

    dynamic fres;

    try {
      fres = featureHook(ctx, 'PrePoint');
      if (fres is Future) {
        await fres;
      }
      ctx.out['point'] = makePoint(ctx);
      if (iserr(ctx.out['point'])) {
        throw ctx.out['point'];
      }

      fres = featureHook(ctx, 'PreSpec');
      if (fres is Future) {
        await fres;
      }
      ctx.out['spec'] = makeSpec(ctx);
      if (iserr(ctx.out['spec'])) {
        throw ctx.out['spec'];
      }

      fres = featureHook(ctx, 'PreRequest');
      if (fres is Future) {
        await fres;
      }
      ctx.out['request'] = await makeRequest(ctx);
      if (iserr(ctx.out['request'])) {
        throw ctx.out['request'];
      }

      fres = featureHook(ctx, 'PreResponse');
      if (fres is Future) {
        await fres;
      }
      ctx.out['response'] = await makeResponse(ctx);
      if (iserr(ctx.out['response'])) {
        throw ctx.out['response'];
      }

      fres = featureHook(ctx, 'PreResult');
      if (fres is Future) {
        await fres;
      }
      ctx.out['result'] = makeResult(ctx);
      if (iserr(ctx.out['result'])) {
        throw ctx.out['result'];
      }

      fres = featureHook(ctx, 'PreDone');
      if (fres is Future) {
        await fres;
      }

      final result = ctx.result;

      // Inbound: prefer the streaming feature's incremental Stream; else fall
      // back to the materialised items so `stream` always yields.
      if (null != result && result.stream is Function) {
        await for (final item in result.stream()) {
          if (_streamAborted(signal)) {
            return;
          }
          yield item;
        }
      } else {
        final data = done(ctx);
        final items = data is List ? data : (null == data ? [] : [data]);
        for (final item in items) {
          if (_streamAborted(signal)) {
            return;
          }
          yield item;
        }
      }
    } catch (err) {
      final uerr = unexpected(ctx, err);
      if (null != uerr) {
        throw uerr;
      }
    }
  }

  bool _streamAborted(dynamic signal) {
    if (null == signal) {
      return false;
    }
    if (signal is Map) {
      return true == signal['aborted'];
    }
    try {
      return true == (signal as dynamic).aborted;
    } catch (_e) {
      return false;
    }
  }

  Map<String, dynamic> toJSON() {
    final struct = utility.struct;
    final out = <String, dynamic>{};
    final d = struct.getdef(dataVal, {});
    if (d is Map) {
      d.forEach((k, v) => out[k.toString()] = v);
    }
  // The marker is NAMESPACED. It used to be `entity$` — a short, generic
  // name, and the `$`-suffix convention is not unique to sdkgen. Seneca uses
  // `entity$` on its own entities to hold the canon, so an SDK record fed
  // into `entize` silently overwrote it and produced entities claiming a
  // canon that does not exist: no error, just wrong entities.
    out[r'voxgig$entity'] = Name;
    return out;
  }

  @override
  String toString() {
    return Name + ' ' + utility.struct.jsonify(dataVal);
  }

  dynamic unexpected(dynamic ctx, dynamic err) {
    final clean = utility.clean;
    final struct = utility.struct;
    final delprop = struct.delprop;

    final ctrl = ctx.ctrl;

    ctrl['err'] = err;

    if (null != ctrl['explain']) {
      ctx.ctrl['explain'] = clean(ctx, ctx.ctrl['explain']);
      delprop(ctx.ctrl['explain']['result'], 'err');

      if (null != ctx.result && null != ctx.result.err) {
        ctrl['explain']['err'] = clean(ctx, {
          'code': errcode(ctx.result.err),
          'message': errmsg(ctx.result.err),
        });
      }

      final cleanerr = clean(ctx, {
        'code': errcode(err),
        'message': errmsg(err),
      });

      if (null == ctrl['explain']['err']) {
        ctrl['explain']['err'] = cleanerr;
      } else if (ctrl['explain']['err']['message'] != cleanerr['message']) {
        ctrl['explain']['unexpected'] = cleanerr;
      }
    }

    if (false == ctrl['throw']) {
      return null;
    }

    return err;
  }
}
