// Primary utility corpus tests. Port of ts test/utility/PrimaryUtility.test.ts:
// drives the scaffold corpus (group "primary") through the SDK's utility
// functions via the VENDORED @voxgig/omni runner, reached through the
// resolver in test/omni.dart (which supersedes the hand-written
// test/runner.dart).
//
// The call sites below are unchanged by the swap: a ctx-carrying entry still
// reaches its subject as a real Context, because the resolver materialises
// one from omni's ctx map at the subject boundary and writes the Context's
// observable state back for `match: {ctx: ...}` (test/omni.dart, decision 3).

import 'harness.dart';
import 'omni.dart';

import '../lib/UnivecSDK.dart';
import '../lib/Point.dart';
import '../lib/UnivecError.dart';
import '../lib/Result.dart';
import '../lib/Spec.dart';
import '../lib/utility/CleanUtility.dart' as cu;
import '../lib/utility/ErrUtility.dart';
import '../lib/utility/voxgig_struct.dart' as vs;

const TEST_JSON_FILE = '../.sdk/test/test.json';

dynamic _spec;
dynamic _runset;
dynamic _client;
dynamic _utility;
Run? _run;

Future<void>? _setupF;

Future<void> _setup() {
  return _setupF ??= () async {
    final runner = makeRunner(TEST_JSON_FILE, UnivecSDK.test());
    final run = runner('primary');

    _run = run;
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

// Drive one primary corpus section by name. A MISSING, non-set or EMPTY
// section fails HERE, before any subject runs — the same guard struct_test's
// `_sec` carries, and the hole this file used to leave open: a fixture that
// shipped `set: []` drove zero assertions and reported PASS (the stale
// "preparePath has no cases" note this file carried was exactly that state
// going unnoticed).
//
// The post-check counts what the ENGINE EXECUTED, not what the spec declares:
// `Run.caseCount` only advances inside omni's execute pass, one increment per
// subject call it actually made (test/omni.dart, decision 1). So the equality
// below is spec-vs-engine, and a disconnected or short-circuited engine fails
// it — a count that could not tell those apart would be worse than none.
Future<void> _sec(String name, dynamic subject) async {
  final secspec = _g(name);
  ok(null != secspec,
      'primary corpus section missing: ' + name +
          ' - check .sdk/test/test.json');

  final testset = vs.getprop(secspec, 'set');
  ok(testset is List && testset.isNotEmpty,
      'primary corpus section is EMPTY: ' + name +
          ' - zero cases would run');

  final declared = (testset as List).length;
  final before = _run!.caseCount;
  await _runset(secspec, subject);
  final drove = _run!.caseCount - before;

  equal(declared, drove,
      'primary corpus section ' + name +
          ' declares cases the engine did not drive');
}

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
      await _sec('makeContext.basic', _utility.makeContext);
    });

    test('method-basic', (t) async {
      await _setup();
      await _sec('prepareMethod.basic', _utility.prepareMethod);
    });

    test('headers-basic', (t) async {
      await _setup();
      await _sec('prepareHeaders.basic', _utility.prepareHeaders);
    });

    test('auth-basic', (t) async {
      await _setup();
      final sdkopts = vs.getpath(_spec, 'prepareAuth.DEF.setup.a') ?? {};
      final authClient = UnivecSDK.test({}, sdkopts);
      await _sec('prepareAuth.basic', (dynamic ctx) {
        ctx.client = authClient;
        _fixctx(ctx);
        return _utility.prepareAuth(ctx);
      });
    });

    test('params-basic', (t) async {
      await _setup();
      await _sec('prepareParams.basic', _utility.prepareParams);
    });

    test('query-basic', (t) async {
      await _setup();
      await _sec('prepareQuery.basic', _utility.prepareQuery);
    });

    // preparePath once shipped as an empty `set: []`, so no port drove it and
    // several kept private hand-written cases instead. It carries real cases
    // now, and `_sec` is what keeps that true: were it emptied again, this
    // case would fail instead of quietly asserting nothing.
    test('path-basic', (t) async {
      await _setup();
      await _sec('preparePath.basic', _utility.preparePath);
    });

    test('body-basic', (t) async {
      await _setup();
      await _sec('prepareBody.basic', (dynamic ctx) {
        _fixctx(ctx);
        return _utility.prepareBody(ctx);
      });
    });

    test('findparam-basic', (t) async {
      await _setup();
      await _sec('param.basic', _utility.param);
    });

    test('fullurl-basic', (t) async {
      await _setup();
      await _sec('makeUrl.basic', _utility.makeUrl);
    });

    // An unfilled route is refused; a placeholder in the base is a server variable.
    test('fullurl-unfilled', (t) async {
      await _setup();
      dynamic urlFor(String base, String path) {
        final ctx = _utility.makeContext({});
        ctx.spec = Spec({'base': base, 'path': path, 'params': <String, dynamic>{}});
        ctx.result = Result({});
        return _utility.makeUrl(ctx);
      }

      final err = urlFor('http://h', 'planet/{planet_id}/moon/{id}');
      ok(err is UnivecError, 'a URL was built: ' + err.toString());
      equal('url_param_missing', err.code);
      equal('URL path has no value for {planet_id}, {id}.', err.message);

      for (final base in [
        'https://api.example.test/bot{token}',
        'http://{{base_url}}',
        'http://{test-base_url}/',
      ]) {
        ok(urlFor(base, 'planet') is String, base);
      }
      equal('URL path has no value for {id}.',
          urlFor('http://{{base_url}}', 'planet/{id}').message);
    });

    test('operator-basic', (t) async {
      await _setup();
      await _sec('operator.basic', (dynamic opmap) {
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
      await _sec('makeOptions.basic', (dynamic vin) {
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
      await _sec('makeSpec.basic', (dynamic ctx) {
        ctx.client = specClient;
        ctx.options = specClient.options();
        return _utility.makeSpec(ctx);
      });
    });

    test('reqform-basic', (t) async {
      await _setup();
      await _sec('transformRequest.basic', _utility.transformRequest);
    });

    test('resform-basic', (t) async {
      await _setup();
      await _sec('transformResponse.basic', _utility.transformResponse);
    });

    test('resbasic-basic', (t) async {
      await _setup();
      await _sec('resultBasic.basic', (dynamic ctx) {
        _fixctx(ctx);
        return _utility.resultBasic(ctx);
      });
    });

    test('resheaders-basic', (t) async {
      await _setup();
      await _sec('resultHeaders.basic', (dynamic ctx) {
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
      await _sec('resultBody.basic', (dynamic ctx) async {
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
      await _sec('makeRequest.basic', (dynamic ctx) async {
        ctx.client = reqClient;
        ctx.utility = reqUtility;
        ctx.options = reqClient.options();
        return reqUtility.makeRequest(ctx);
      });
    });

    test('response-basic', (t) async {
      await _setup();
      await _sec('makeResponse.basic', (dynamic ctx) async {
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
      await _sec('done.basic', (dynamic ctx) {
        _fixctx(ctx);
        return _utility.done(ctx);
      });
    });

    test('error-basic', (t) async {
      await _setup();
      await _sec('makeError.basic', (dynamic ctx, [dynamic err]) {
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

    test('makeError-cleans-the-code', (t) async {
      await _setup();
      final ctx = _makeFullCtx();
      ctx.ctrl['throw'] = false;
      cu.cleanAdd(ctx, 'CODE-SECRET-12');
      _utility.makeError(ctx, ctx.error('refused_CODE-SECRET-12', 'refused'));
      equal('refused_[redacted]', ctx.ctrl['err'].code);
      ok(!ctx.ctrl['err'].toString().contains('CODE-SECRET-12'));
    });

    test('clean-with-a-huge-hint-still-masks', (t) async {
      final ctx = {
        'options': {
          '__derived__': {
            'clean': cu.makeCleanConfig(
                {...cu.CLEAN_OPTSPEC, 'hint': '5000000000000000000'})
          }
        }
      };
      cu.cleanAdd(ctx, 'HINT-SECRET-abcdef');
      equal('k [redacted]', cu.clean(ctx, 'k HINT-SECRET-abcdef'));
    });

    test('clean-masks-registered-property-names', (t) async {
      final ctx = {
        'options': {
          '__derived__': {'clean': cu.makeCleanConfig(cu.CLEAN_OPTSPEC)}
        }
      };
      cu.cleanAdd(ctx, 'ZZVAL-abc123');
      cu.cleanAdd(ctx, 'ZZVAL-xyz789');
      final out =
          cu.clean(ctx, {'ZZVAL-abc123': 1, 'ZZVAL-xyz789': 2, 'plain': 3});
      deepEqual(out, {'[redacted]': 1, '[redacted]#1': 2, 'plain': 3});
    });

    test('cleanAddSensitive-registers-every-scalar-under-a-sensitive-name',
        (t) async {
      final cfg = cu.makeCleanConfig(cu.CLEAN_OPTSPEC);
      final ctx = {
        'options': {
          '__derived__': {'clean': cfg}
        }
      };
      cu.cleanAddSensitive(ctx, {
        'apikey': {'value': 'NESTED-SECRET-1'},
        'headers': {
          'X-Api-Token': ['LISTED-SECRET-2']
        },
        'secret': 123456789,
        'name': 'not-a-secret',
      });
      final List values = cfg['values'];
      ok(values.contains('NESTED-SECRET-1'));
      ok(values.contains('LISTED-SECRET-2'));
      ok(values.contains('123456789'));
      ok(!values.contains('not-a-secret'));

      final loop = <String, dynamic>{'token': 'LOOP-SECRET-3'};
      loop['self'] = loop;
      cu.cleanAddSensitive(ctx, loop);
      ok(values.contains('LOOP-SECRET-3'));
    });

    test('clean-honours-the-config-clean-block', (t) async {
      await _setup();
      final dynamic config = {
        'options': {
          'clean': {'keys': 'zzsens', 'values': 'CONFIG-SEEDED-1'}
        }
      };
      final ctx = _utility.makeContext({
        'options': {
          'clean': {'values': 'CALLER-SEEDED-2'}
        },
        'config': config,
      });
      ctx.client = _client;
      ctx.utility = _client.utility();
      ctx.options = _utility.makeOptions(ctx);
      equal('a [redacted] b [redacted]',
          cu.clean(ctx, 'a CONFIG-SEEDED-1 b CALLER-SEEDED-2'));
      deepEqual(cu.clean(ctx, {'my_zzsens': 'x', 'other': 'y'}),
          {'my_zzsens': '[redacted]', 'other': 'y'});
      equal('CONFIG-SEEDED-1', config['options']['clean']['values']);
    });

    test('options-stay-with-their-client', (t) async {
      UnivecSDK({
        'headers': {'X-Custom-Token': 'FIRST-CLIENT-TOKEN'}
      });
      final second = UnivecSDK({});
      equal(null, vs.getpath(second.options(), 'headers.X-Custom-Token'));
    });

    test('feature-names-do-not-make-settings-sensitive', (t) async {
      await _setup();
      final ctx = _utility.makeContext({
        'options': {
          'feature': {
            'secrets': {
              'active': false,
              'kind': 'vaultish',
              'token': 'REAL-TOKEN-1'
            }
          }
        },
        'config': <String, dynamic>{},
      });
      ctx.client = _client;
      ctx.utility = _client.utility();
      ctx.options = _utility.makeOptions(ctx);
      final List values = ctx.options['__derived__']['clean']['values'];
      ok(values.contains('REAL-TOKEN-1'));
      ok(!values.contains('vaultish'), 'a feature name made its settings secret');
      equal('unknown provider kind: vaultish',
          cu.clean(ctx, 'unknown provider kind: vaultish'));
    });

    test('entity-blocks-are-not-read', (t) async {
      await _setup();
      Map<String, dynamic> seeded(Map<String, dynamic> block) => {
            ...block,
            'entity': {
              'zztoken': {
                'ZZTOKEN01': {'id': 'ZZTOKEN01', 'note': 'PLAINRECORD-t5r3e1w9'}
              }
            },
          };
      final features = <String, dynamic>{
        'zzfeat': {'active': false, 'apitoken': 'FEATTOKEN-z9y8x7w6'},
        'test': seeded({'active': false}),
      };
      for (final feature in [
        features,
        [
          for (final e in features.entries) {'name': e.key, ...e.value}
        ],
      ]) {
        final ctx = _utility.makeContext({
          'options': {
            'feature': feature,
            'test': seeded({}),
            'entity': {
              'zztoken': {
                'alias': {'zzkey': 'PLAINALIAS-m2n4b6v8'}
              }
            },
          },
          'config': <String, dynamic>{},
        });
        ctx.client = _client;
        ctx.utility = _client.utility();
        ctx.options = _utility.makeOptions(ctx);
        final List values = ctx.options['__derived__']['clean']['values'];
        ok(values.contains('FEATTOKEN-z9y8x7w6'));
        for (final plain in [
          'ZZTOKEN01',
          'PLAINRECORD-t5r3e1w9',
          'PLAINALIAS-m2n4b6v8'
        ]) {
          ok(!values.contains(plain), 'an entity block registered ' + plain);
        }
        equal('record PLAINRECORD-t5r3e1w9',
            cu.clean(ctx, 'record PLAINRECORD-t5r3e1w9'));
        equal('alias PLAINALIAS-m2n4b6v8',
            cu.clean(ctx, 'alias PLAINALIAS-m2n4b6v8'));
      }
    });

    // The whole-suite backstop, behind `_sec`'s per-section guards: those
    // pin each section to the case count the engine actually drove for it,
    // so a shrunken or emptied section fails in its own case, named. This
    // catches what they cannot — a drive site DELETED outright, which takes
    // its guard with it. Runs last, so it sees every case above.
    test('corpus-cases', (t) async {
      await _setup();
      final cases = _run!.caseCount;
      print('primary corpus: cases ' + cases.toString());
      ok(60 < cases,
          'primary corpus drove only ' + cases.toString() +
              ' cases - the corpus stopped running');
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
