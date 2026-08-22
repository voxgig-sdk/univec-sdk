// Primary utility corpus tests. Port of ts test/utility/PrimaryUtility.test.ts:
// drives the scaffold corpus (group "primary") through the SDK's utility
// functions via the ported runner (test/runner.dart).

import 'harness.dart';
import 'runner.dart';

import '../lib/UnivecSDK.dart';
import '../lib/Point.dart';
import '../lib/utility/ErrUtility.dart';
import '../lib/utility/voxgig_struct.dart' as vs;

const TEST_JSON_FILE = '../.sdk/test/test.json';

dynamic _spec;
dynamic _runset;
dynamic _client;
dynamic _utility;

Future<void>? _setupF;

Future<void> _setup() {
  return _setupF ??= () async {
    final runner = await makeRunner(TEST_JSON_FILE, UnivecSDK.test());
    final run = await runner('primary');

    _spec = run.spec;
    _runset = run.runset;
    _client = run.client;
    _utility = _client.utility();
  }();
}

// Ensure ctx has options derived from client when needed.
void _fixctx(dynamic ctx) {
  if (null != ctx && null != ctx.client && null == ctx.options) {
    ctx.options = ctx.client.options();
  }
}

dynamic _g(String path) => vs.getpath(_spec, path);

void tests() {
  describe('PrimaryUtility', () {
    test('exists', (t) async {
      await _setup();
      const fns = [
        'clean', 'done', 'makeError', 'featureAdd', 'featureHook',
        'featureInit', 'fetcher', 'makeFetchDef', 'makeContext',
        'makeOptions', 'makeRequest', 'makeResponse', 'makeResult',
        'makePoint', 'makeSpec', 'makeUrl', 'param', 'prepareAuth',
        'prepareBody', 'prepareHeaders', 'prepareMethod', 'prepareParams',
        'preparePath', 'prepareQuery', 'resultBasic', 'resultBody',
        'resultHeaders', 'transformRequest', 'transformResponse',
      ];
      for (final fn in fns) {
        ok(null != _utility.byName(fn), fn + ' should be a function');
      }
    });

    test('context-basic', (t) async {
      await _setup();
      await _runset(_g('makeContext.basic'), _utility.makeContext);
    });

    test('method-basic', (t) async {
      await _setup();
      await _runset(_g('prepareMethod.basic'), _utility.prepareMethod);
    });

    test('headers-basic', (t) async {
      await _setup();
      await _runset(_g('prepareHeaders.basic'), _utility.prepareHeaders);
    });

    test('auth-basic', (t) async {
      await _setup();
      final sdkopts = vs.getpath(_spec, 'prepareAuth.DEF.setup.a') ?? {};
      final authClient = UnivecSDK.test({}, sdkopts);
      await _runset(_g('prepareAuth.basic'), (dynamic ctx) {
        ctx.client = authClient;
        _fixctx(ctx);
        return _utility.prepareAuth(ctx);
      });
    });

    test('params-basic', (t) async {
      await _setup();
      await _runset(_g('prepareParams.basic'), _utility.prepareParams);
    });

    test('query-basic', (t) async {
      await _setup();
      await _runset(_g('prepareQuery.basic'), _utility.prepareQuery);
    });

    // preparePath shipped as an empty `set: []`, so no port drove it and
    // several kept private hand-written cases instead.
    test('path-basic', (t) async {
      await _setup();
      await _runset(_g('preparePath.basic'), _utility.preparePath);
    });

    test('body-basic', (t) async {
      await _setup();
      await _runset(_g('prepareBody.basic'), (dynamic ctx) {
        _fixctx(ctx);
        return _utility.prepareBody(ctx);
      });
    });

    test('findparam-basic', (t) async {
      await _setup();
      await _runset(_g('param.basic'), _utility.param);
    });

    test('fullurl-basic', (t) async {
      await _setup();
      await _runset(_g('makeUrl.basic'), _utility.makeUrl);
    });

    test('operator-basic', (t) async {
      await _setup();
      await _runset(_g('operator.basic'), (dynamic opmap) {
        return {
          'entity': opmap['entity'] ?? '_',
          'name': opmap['name'] ?? '_',
          'input': opmap['input'] ?? '_',
          'points': opmap['points'] ?? [],
        };
      });
    });

    test('options-basic', (t) async {
      await _setup();
      await _runset(_g('makeOptions.basic'), (dynamic vin) {
        final ctx = _utility.makeContext(
            {'options': vin['options'], 'config': vin['config']});
        ctx.client = _client;
        ctx.utility = _client.utility();
        return _utility.makeOptions(ctx);
      });
    });

    test('spec-basic', (t) async {
      await _setup();
      final sdkopts = vs.getpath(_spec, 'makeSpec.DEF.setup.a') ?? {};
      final specClient = UnivecSDK.test({}, sdkopts);
      await _runset(_g('makeSpec.basic'), (dynamic ctx) {
        ctx.client = specClient;
        ctx.options = specClient.options();
        return _utility.makeSpec(ctx);
      });
    });

    test('reqform-basic', (t) async {
      await _setup();
      await _runset(_g('transformRequest.basic'), _utility.transformRequest);
    });

    test('resform-basic', (t) async {
      await _setup();
      await _runset(_g('transformResponse.basic'), _utility.transformResponse);
    });

    test('resbasic-basic', (t) async {
      await _setup();
      await _runset(_g('resultBasic.basic'), (dynamic ctx) {
        _fixctx(ctx);
        return _utility.resultBasic(ctx);
      });
    });

    test('resheaders-basic', (t) async {
      await _setup();
      await _runset(_g('resultHeaders.basic'), (dynamic ctx) {
        // Header keys reach the pipeline lowercased by the transport.
        if (null != ctx.response && ctx.response.headers is Map) {
          final h = <String, dynamic>{};
          (ctx.response.headers as Map)
              .forEach((k, v) => h[k.toString().toLowerCase()] = v);
          ctx.response.headers = h;
        }
        return _utility.resultHeaders(ctx);
      });
    });

    test('resbody-basic', (t) async {
      await _setup();
      await _runset(_g('resultBody.basic'), (dynamic ctx) async {
        if (null != ctx.response && null == ctx.response.jsonFn) {
          final body = ctx.response.body;
          ctx.response.jsonFn = () => body;
        }
        return _utility.resultBody(ctx);
      });
    });

    test('request-basic', (t) async {
      await _setup();
      mockFetch(dynamic url, dynamic init) async => {
            'status': 200,
            'statusText': 'OK',
            'headers': {'content-type': 'application/json'},
            'json': () => {'id': 'res01'},
            'body': 'present',
          };
      final reqClient = UnivecSDK({
        'system': {'fetch': mockFetch}
      });
      final reqUtility = reqClient.utility();
      await _runset(_g('makeRequest.basic'), (dynamic ctx) async {
        ctx.client = reqClient;
        ctx.utility = reqUtility;
        ctx.options = reqClient.options();
        return reqUtility.makeRequest(ctx);
      });
    });

    test('response-basic', (t) async {
      await _setup();
      await _runset(_g('makeResponse.basic'), (dynamic ctx) async {
        _fixctx(ctx);
        if (null != ctx.response && null == ctx.response.jsonFn) {
          final body = ctx.response.body;
          ctx.response.jsonFn = () => body;
        }
        if (null != ctx.response && ctx.response.headers is Map) {
          final h = <String, dynamic>{};
          (ctx.response.headers as Map)
              .forEach((k, v) => h[k.toString().toLowerCase()] = v);
          ctx.response.headers = h;
        }
        return _utility.makeResponse(ctx);
      });
    });

    test('done-basic', (t) async {
      await _setup();
      await _runset(_g('done.basic'), (dynamic ctx) {
        _fixctx(ctx);
        return _utility.done(ctx);
      });
    });

    test('error-basic', (t) async {
      await _setup();
      await _runset(_g('makeError.basic'), (dynamic ctx, [dynamic err]) {
        _fixctx(ctx);
        return _utility.makeError(ctx, err);
      });
    });

    test('makePoint-single', (t) async {
      await _setup();
      final ctx = _makeCtx();
      final point = Point({
        'parts': ['items', '{id}'],
        'args': {'params': []},
        'params': [],
        'alias': {},
        'select': {},
        'active': true,
        'transform': {'req': null, 'res': null},
      });
      ctx.op.points = [point];

      final result = _utility.makePoint(ctx);
      ok(!iserr(result));
      equal(true, identical(ctx.point, point));
    });

    test('makeFetchDef', (t) async {
      await _setup();
      final ctx = _makeFullCtx();
      ctx.spec = _specOf({
        'base': 'http://localhost:8080',
        'prefix': '/api',
        'path': 'items/{id}',
        'suffix': '',
        'params': {'id': 'item01'},
        'query': {},
        'headers': {'content-type': 'application/json'},
        'method': 'GET',
        'step': 'start',
      });

      final fetchdef = _utility.makeFetchDef(ctx);
      ok(!iserr(fetchdef), 'should not be error');
      equal('GET', fetchdef['method']);
      ok(fetchdef['url'].toString().contains('/api/items/item01'));
      equal('application/json', fetchdef['headers']['content-type']);
      ok(null == fetchdef['body']);
    });

    test('makeFetchDef-with-body', (t) async {
      await _setup();
      final ctx = _makeFullCtx();
      ctx.spec = _specOf({
        'base': 'http://localhost:8080',
        'prefix': '',
        'path': 'items',
        'suffix': '',
        'params': {},
        'query': {},
        'headers': {},
        'method': 'POST',
        'step': 'start',
        'body': {'name': 'n0'},
      });

      final fetchdef = _utility.makeFetchDef(ctx);
      ok(!iserr(fetchdef));
      equal('POST', fetchdef['method']);
      ok(fetchdef['body'] is String);
      ok(fetchdef['body'].toString().contains('"n0"'));
    });

    test('fetcher-live', (t) async {
      await _setup();
      final calls = <Map<String, dynamic>>[];
      final liveClient = UnivecSDK({
        'system': {
          'fetch': (dynamic url, dynamic init) async {
            calls.add({'url': url, 'init': init});
            return {'status': 200, 'statusText': 'OK'};
          }
        }
      });
      final liveUtility = liveClient.utility();
      final ctx =
          liveUtility.makeContext({'opname': 'load'}, liveClient.rootctx);
      ctx.client = liveClient;

      final fetchdef = {'method': 'GET', 'headers': {}};
      final response =
          await liveUtility.fetcher(ctx, 'http://example.com/test', fetchdef);
      ok(!iserr(response));
      equal(1, calls.length);
      equal('http://example.com/test', calls[0]['url']);
    });

    test('fetcher-blocked-test-mode', (t) async {
      await _setup();
      final blockedClient = UnivecSDK({
        'system': {'fetch': (dynamic url, dynamic init) async => {}}
      });
      blockedClient.mode = 'test';

      final blockedUtility = blockedClient.utility();
      final ctx = blockedUtility
          .makeContext({'opname': 'load'}, blockedClient.rootctx);
      ctx.client = blockedClient;
      final fetchdef = {'method': 'GET', 'headers': {}};

      final result = await blockedUtility.fetcher(
          ctx, 'http://example.com/test', fetchdef);
      ok(iserr(result));
      ok(errmsg(result).contains('mode'));
    });

    test('makeError-no-throw', (t) async {
      await _setup();
      final ctx = _makeFullCtx();
      ctx.ctrl['throw'] = false;
      ctx.result = _resultOf({
        'ok': false,
        'resdata': {'id': 'safe01'},
      });

      final out =
          _utility.makeError(ctx, ctx.error('test_code', 'test message'));
      deepEqual(out, {'id': 'safe01'});
    });

    test('clean', (t) async {
      await _setup();
      final ctx = _makeFullCtx();
      final val = {'key': 'secret123', 'name': 'test'};
      final cleaned = _utility.clean(ctx, val);
      ok(null != cleaned);
    });
  });
}

// Helper functions for manual tests
dynamic _makeCtx([Map<String, dynamic>? overrides]) {
  final ctxmap = <String, dynamic>{'opname': 'load'};
  overrides?.forEach((k, v) => ctxmap[k] = v);
  return _utility.makeContext(ctxmap, _client.rootctx);
}

dynamic _makeFullCtx([Map<String, dynamic>? overrides]) {
  final ctx = _makeCtx(overrides);
  ctx.point = Point({
    'parts': ['items', '{id}'],
    'args': {
      'params': [
        {'name': 'id', 'reqd': true}
      ]
    },
    'params': ['id'],
    'alias': {},
    'select': {},
    'active': true,
    'relations': [],
    'transform': {'req': null, 'res': null},
  });
  ctx.match = {'id': 'item01'};
  ctx.reqmatch = {'id': 'item01'};
  return ctx;
}

dynamic _specOf(Map<String, dynamic> m) =>
    (_utility.makeContext({'spec': m}) as dynamic).spec;

dynamic _resultOf(Map<String, dynamic> m) =>
    (_utility.makeContext({'result': m}) as dynamic).result;
