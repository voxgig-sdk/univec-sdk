import 'dart:math';

import 'UnivecError.dart';

import 'utility/voxgig_struct.dart' as vs;

import 'Operation.dart';
import 'Point.dart';
import 'Response.dart';
import 'Result.dart';
import 'Spec.dart';

class Context {
  String id = 'C' +
      (Random().nextInt(0x3fffffff) + 0x40000000).toString().substring(0, 8);

  // Store the output of each operation step.
  Map<String, dynamic> out = {};

  // Per-operation control settings (plain map: throw, explain, actor, ...).
  dynamic ctrl = {};
  dynamic meta = {};

  dynamic client;
  dynamic utility;

  dynamic op;
  dynamic point;

  dynamic config;
  dynamic entopts;
  dynamic options;

  dynamic opmap;

  dynamic response;
  dynamic result;
  dynamic spec;

  dynamic data;
  dynamic reqdata;
  dynamic match;
  dynamic reqmatch;

  dynamic entity;

  // Shared persistent store.
  dynamic shared;

  Context(dynamic ctxmap, [dynamic basectx]) {
    client = vs.getprop(ctxmap, 'client') ?? basectx?.client;
    utility = vs.getprop(ctxmap, 'utility') ?? basectx?.utility;

    final rawctrl = vs.getprop(ctxmap, 'ctrl');
    ctrl = null != rawctrl
        ? (rawctrl is Map && rawctrl is! Map<String, dynamic>
            ? Map<String, dynamic>.from(rawctrl)
            : rawctrl)
        : (basectx?.ctrl ?? {});
    meta = vs.getprop(ctxmap, 'meta') ?? basectx?.meta ?? {};

    config = vs.getprop(ctxmap, 'config') ?? basectx?.config;
    entopts = vs.getprop(ctxmap, 'entopts') ?? basectx?.entopts;
    options = vs.getprop(ctxmap, 'options') ?? basectx?.options;

    entity = vs.getprop(ctxmap, 'entity') ?? basectx?.entity;
    shared = vs.getprop(ctxmap, 'shared') ?? basectx?.shared;
    opmap = vs.getprop(ctxmap, 'opmap') ?? basectx?.opmap ?? {};

    data = vs.getprop(ctxmap, 'data', {});
    reqdata = vs.getprop(ctxmap, 'reqdata', {});
    match = vs.getprop(ctxmap, 'match', {});
    reqmatch = vs.getprop(ctxmap, 'reqmatch', {});

    point = _aspoint(vs.getprop(ctxmap, 'point')) ?? basectx?.point;
    spec = _asspec(vs.getprop(ctxmap, 'spec')) ?? basectx?.spec;
    result = _asresult(vs.getprop(ctxmap, 'result')) ?? basectx?.result;
    response = _asresponse(vs.getprop(ctxmap, 'response')) ?? basectx?.response;

    final opname = vs.getprop(ctxmap, 'opname');
    op = resolveOp(opname);
  }

  // JSON-sourced context maps carry plain maps for the pipeline value
  // classes; coerce them so utilities can use typed member access.
  dynamic _aspoint(dynamic v) => v is Map ? Point(v) : v;
  dynamic _asspec(dynamic v) => v is Map ? Spec(v) : v;
  dynamic _asresult(dynamic v) => v is Map ? Result(v) : v;
  dynamic _asresponse(dynamic v) => v is Map ? Response(v) : v;

  dynamic resolveOp(dynamic opname) {
    // Cache key is `<entity>:<opname>` so two entities with the same op
    // (e.g. both have a "list") get distinct cached Operations. Keying on
    // opname alone caused the first-resolved entity's points to be served
    // to every subsequent entity's call.
    var entname = '';
    final ent = entity;
    if (null != ent) {
      if (ent is Map) {
        entname = vs.getprop(ent, 'name', '') ?? '';
      } else {
        try {
          entname = (ent.name ?? '') as String;
        } catch (_e) {
          entname = '';
        }
      }
    }

    final cacheKey = entname + ':' + ('' + (opname ?? '').toString());
    dynamic op = vs.getprop(opmap, cacheKey);

    if (null == op && null != opname) {
      final opcfg = vs.getpath(config, ['entity', entname, 'op', opname]);
      var input = 'match';

      if ('update' == opname || 'create' == opname) {
        input = 'data';
      }

      op = Operation({
        'entity': entname,
        'name': opname,
        'input': input,
        'points': vs.getprop(opcfg, 'points', []),
      });

      vs.setprop(opmap, cacheKey, op);
    }

    return op;
  }

  UnivecError error(String code, String msg) {
    return UnivecError(code, msg, this);
  }

  Map<String, dynamic> toJSON() => {
        'id': id,
        'op': op,
        'spec': spec,
        'entity': entity,
        'result': result,
        'response': response,
        'meta': meta,
      };

  @override
  String toString() => 'Context ' + id;
}
