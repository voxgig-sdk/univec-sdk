// Offline feature-test harness for the generated SDK.
//
// Feature behaviour (retry, cache, rbac, telemetry, ...) is unit-tested by
// driving each feature class through a faithful miniature of the real
// operation pipeline against a configurable mock transport — the same hook
// order and short-circuit rules as the generated entity op code, but with
// no live server and no API-specific fixtures. Feature instances are built
// via `config.makeFeature`, so only features actually present in this SDK
// are exercised (see `hasFeature`). Port of ts test/feature/harness.ts.

import 'dart:async';

import '../../lib/UnivecSDK.dart';
import '../../lib/UnivecError.dart';
import '../../lib/Config.dart';
import '../../lib/Operation.dart';
import '../../lib/Response.dart';
import '../../lib/Result.dart';
import '../../lib/Spec.dart';
import '../../lib/utility/ErrUtility.dart';
import '../../lib/utility/Utility.dart';

// True when this SDK was generated with the named feature.
bool hasFeature(String name) => null != config.feature[name];

// A deterministic virtual clock: `now()` advances only when `sleep(ms)` is
// called, so timing-based features can be asserted without real delays.
class Clock {
  num t;
  Clock([this.t = 0]);
  num now() => t;
  void sleep(dynamic ms) {
    t += (ms is num ? ms : 0);
  }

  void advance(num ms) {
    t += ms;
  }

  num get time => t;
}

Clock makeClock([num start = 0]) => Clock(start);

// Build a transport-shaped response the pipeline understands.
Map<String, dynamic> makeResponse(int status,
    [dynamic data, Map<String, dynamic>? headers]) {
  final h = <String, dynamic>{};
  (headers ?? {}).forEach((k, v) => h[k.toLowerCase()] = v);
  return {
    'status': status,
    'statusText': status < 400 ? 'OK' : 'ERR',
    'body': 'not-used',
    'json': () => data,
    'headers': h,
  };
}

typedef ServerFn = dynamic Function(dynamic ctx, dynamic url, dynamic fetchdef);

ServerFn defaultServer() {
  return (dynamic _ctx, dynamic _url, dynamic fetchdef) {
    final method = (fetchdef['method'] ?? 'GET').toString().toUpperCase();
    if ('GET' == method) {
      return makeResponse(200, {'ok': true, 'method': method});
    }
    return makeResponse(200, {'ok': true, 'method': method, 'echo': fetchdef['body']});
  };
}

String defaultMethod(String op) {
  if ('create' == op) return 'POST';
  if ('update' == op) return 'PATCH';
  if ('remove' == op) return 'DELETE';
  return 'GET';
}

// A minimal client shape: exactly the surface features touch.
class HarnessClient {
  String mode = 'test';
  List features = [];
  final Map<String, dynamic> track = {};
  Map<String, dynamic> opts = {};
  Utility util = Utility();

  dynamic options() => opts;
  dynamic utility() => util;
}

class Harness {
  late HarnessClient client;
  late Utility utility;
  dynamic rootctx;
  late Future<dynamic> Function(Map<String, dynamic> o) op;
  late Future<void> Function() ready;
  late dynamic Function(String name) feature;
}

// Construct a fake client wired with the given features (in init order) and
// a mini operation pipeline. `features` is a list of {name, options} maps.
Harness makeClient({
  required List<Map<String, dynamic>> features,
  ServerFn? server,
  String? mode,
  String? base,
  Map<String, dynamic>? headers,
}) {
  final b = base ?? 'http://api.test';
  final srv = server ?? defaultServer();

  final utility = Utility();
  utility.fetcher = srv;

  final client = HarnessClient();
  client.mode = mode ?? 'test';
  client.util = utility;
  client.opts = {
    'base': b,
    'headers': headers ?? {},
    'feature': {},
  };

  var idseq = 0;
  final rootShared = {};

  dynamic makeCtx(Map<String, dynamic> over) {
    idseq++;
    final ctx = utility.makeContext({
      'client': client,
      'utility': utility,
      'ctrl': over['ctrl'] ?? {},
      'entity': over['entity'],
      'shared': rootShared,
    });
    ctx.id = 'C' + idseq.toString();
    final opdef = over['op'];
    ctx.op = null == opdef ? null : Operation(opdef);
    return ctx;
  }

  Future<void> featureHook(dynamic ctx, String name) async {
    final resp = <Future>[];
    for (final f in client.features) {
      final r = (f as dynamic).invokeHook(name, ctx);
      if (r is Future) {
        resp.add(r);
      }
    }
    if (resp.isNotEmpty) {
      await Future.wait(resp);
    }
  }

  final rootctx = makeCtx({
    'op': {'name': 'root', 'entity': '_'},
  });

  // Instantiate + init the requested features (skipping any not present in
  // this SDK), then fire PostConstruct.
  for (final fspec in features) {
    final fname = fspec['name'].toString();
    if (!hasFeature(fname)) {
      continue;
    }
    final f = config.makeFeature(fname);
    final fopts = <String, dynamic>{'active': true};
    final fo = fspec['options'];
    if (fo is Map) {
      fo.forEach((k, v) => fopts[k.toString()] = v);
    }
    (client.opts['feature'] as Map)[f.name] = fopts;
    f.init(rootctx, fopts);
    client.features.add(f);
  }

  String buildUrl(dynamic sp) {
    final q = sp.query ?? {};
    final keys = (q as Map)
        .keys
        .where((k) => null != q[k])
        .map((k) => k.toString())
        .toList()
      ..sort();
    final qs = keys
        .map((k) =>
            Uri.encodeComponent(k) + '=' + Uri.encodeComponent(q[k].toString()))
        .join('&');
    return sp.base.toString() +
        (sp.path ?? '').toString() +
        ('' == qs ? '' : '?' + qs);
  }

  Future<void> populateResult(dynamic ctx, dynamic response) async {
    final result = Result({});
    ctx.result = result;

    if (iserr(response)) {
      result.err = response;
      return;
    }
    result.status = response['status'];
    result.statusText = response['statusText'];
    final h = response['headers'];
    if (h is Map) {
      final out = <String, dynamic>{};
      h.forEach((k, v) => out[k.toString()] = v);
      result.headers = out;
    }
    final jsonFn = response['json'];
    if (jsonFn is Function) {
      result.body = await Future.value(jsonFn());
    }
    result.resdata = result.body;
    if (result.status is num && result.status >= 400) {
      result.err = UnivecError('request_status',
          'request: ' + result.status.toString() + ': ' + result.statusText.toString(), ctx);
    } else if (null != response['err']) {
      result.err = response['err'];
    }
    if (null == result.err) {
      result.ok = true;
    }
  }

  // Run one operation through the mini pipeline (mirrors the generated
  // entity op fragment: hook, short-circuit, make*, hook, ...).
  Future<dynamic> op(Map<String, dynamic> o) async {
    final entity = (o['entity'] ?? 'widget').toString();
    final opname = (o['op'] ?? 'load').toString();
    final method = (o['method'] ?? defaultMethod(opname)).toString();

    final ctx = makeCtx({
      'op': {'name': opname, 'entity': entity},
      'entity': {'name': entity},
      'ctrl': o['ctrl'] ?? {},
    });

    await featureHook(ctx, 'PostConstructEntity');

    try {
      await featureHook(ctx, 'PrePoint');
      if (iserr(ctx.out['point'])) {
        throw ctx.out['point'];
      }

      await featureHook(ctx, 'PreSpec');
      final headersMap = <String, dynamic>{};
      (headers ?? {}).forEach((k, v) => headersMap[k.toString()] = v);
      final oh = o['headers'];
      if (oh is Map) {
        oh.forEach((k, v) => headersMap[k.toString()] = v);
      }
      ctx.spec = ctx.out['spec'] ??
          Spec({
            'method': method,
            'base': b,
            'path': o['path'] ?? ('/' + entity),
            'params': {},
            'headers': headersMap,
            'query': o['query'] ?? {},
            'body': o['body'],
            'step': 'start',
          });

      await featureHook(ctx, 'PreRequest');
      ctx.spec.url = buildUrl(ctx.spec);

      dynamic response;
      if (null != ctx.out['request']) {
        response = ctx.out['request'];
      } else {
        final fetchdef = <String, dynamic>{
          'url': ctx.spec.url,
          'method': ctx.spec.method,
          'headers': ctx.spec.headers,
          'body': ctx.spec.body,
        };
        response =
            await Future.value(utility.fetcher(ctx, fetchdef['url'], fetchdef));
      }
      ctx.response = iserr(response)
          ? Response({'err': response})
          : (response is Map ? Response(response) : response);

      await featureHook(ctx, 'PreResponse');
      await populateResult(ctx, response);
      await featureHook(ctx, 'PreResult');
      await featureHook(ctx, 'PreDone');

      if (null != ctx.result && true == ctx.result.ok) {
        return {
          'ok': true,
          'data': ctx.result.resdata,
          'result': ctx.result,
          'ctx': ctx,
        };
      }
      throw (null != ctx.result ? ctx.result.err : null) ??
          ctx.error('op_failed', 'operation failed');
    } catch (err) {
      if (ctx.ctrl is Map) {
        ctx.ctrl['err'] = err;
      }
      await featureHook(ctx, 'PreUnexpected');
      return {'ok': false, 'error': err, 'result': ctx.result, 'ctx': ctx};
    }
  }

  final boot = featureHook(rootctx, 'PostConstruct');

  final h = Harness();
  h.client = client;
  h.utility = utility;
  h.rootctx = rootctx;
  h.op = op;
  h.ready = () async {
    await boot;
  };
  h.feature = (String name) {
    for (final f in client.features) {
      if ((f as dynamic).name == name) {
        return f;
      }
    }
    return null;
  };

  return h;
}
