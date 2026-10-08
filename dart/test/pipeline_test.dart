// Direct unit tests for the operation-pipeline utilities. The generated
// entity tests exercise the happy path; these drive the error and edge
// branches (missing spec/response/result, 4xx handling, transport
// failures, feature ordering, auth header shaping) that a normal
// success-path op never reaches. All utilities are reached through
// `stdutil`, so this suite is API-agnostic. Port of ts test/pipeline.test.ts.

import 'dart:io' show ContentType, HttpServer, InternetAddress;

import 'harness.dart';

import '../lib/UnivecSDK.dart';
import '../lib/UnivecError.dart';
import '../lib/Operation.dart';
import '../lib/Point.dart';
import '../lib/Response.dart';
import '../lib/Result.dart';
import '../lib/Spec.dart';
import '../lib/feature/base/BaseFeature.dart';
import '../lib/utility/ErrUtility.dart';
import '../lib/utility/FetcherUtility.dart' show defaultUserAgent, httpFetch;
import '../lib/utility/Utility.dart';
import '../lib/utility/voxgig_struct.dart' as vs;
import '../lib/feature/test/TestFeature.dart';

// Transport-shaped response with a re-readable body + lowercased headers.
Map<String, dynamic> resp(int status, [dynamic data, Map<String, dynamic>? headers]) {
  final h = <String, dynamic>{};
  (headers ?? {}).forEach((k, v) => h[k.toLowerCase()] = v);
  return {
    'status': status,
    'statusText': status < 400 ? 'OK' : 'ERR',
    'body': 'body',
    'json': () => data,
    'headers': h,
  };
}

dynamic base([Map<String, dynamic>? over]) {
  final ctx = stdutil.makeContext({});
  ctx.utility = stdutil;
  ctx.ctrl = {};
  ctx.op = Operation({'name': 'load', 'entity': 'x'});
  over?.forEach((k, v) {
    switch (k) {
      case 'op':
        ctx.op = v is Operation || null == v ? v : Operation(v);
        break;
      case 'options':
        ctx.options = v;
        break;
      case 'spec':
        ctx.spec = v is Map ? Spec(v) : v;
        break;
      case 'response':
        ctx.response = v is Map ? Response(v) : v;
        break;
      case 'result':
        ctx.result = v is Map ? Result(v) : v;
        break;
      case 'out':
        ctx.out = Map<String, dynamic>.from(v);
        break;
      case 'ctrl':
        ctx.ctrl = v is Map ? Map<String, dynamic>.from(v) : v;
        break;
      case 'utility':
        ctx.utility = v;
        break;
      case 'entity':
        ctx.entity = v;
        break;
      case 'client':
        ctx.client = v;
        break;
    }
  });
  return ctx;
}

// A utility whose fetcher (or other member) is overridden (makeRequest tests).
Utility utilWith(dynamic fetcher) {
  final u = Utility();
  u.fetcher = fetcher;
  return u;
}

// Entity fake for the list-wrapping test.
class _FakeEnt {
  final List made;
  _FakeEnt(this.made);
  String get name => 'x';
  dynamic make() => _FakeEnt(made);
  dynamic data(dynamic d) {
    made.add(d);
  }
}

// Client fake exposing only options() (prepareAuth tests).
class _OptClient {
  final dynamic opts;
  _OptClient(this.opts);
  dynamic options() => opts;
}

// Client fake exposing only features (featureAdd tests).
class _FeatClient {
  List features = [];
}

BaseFeature _feat(String name, [Map<String, dynamic>? opts]) {
  final f = BaseFeature();
  f.name = name;
  if (null != opts) {
    f.options = opts;
  }
  return f;
}

const allow = {
  'op': 'load,list,create,update,remove',
  'method': 'GET,PUT,POST,PATCH,DELETE'
};

void tests() {
  describe('pipeline:makePoint + makeSpec', () {
    test('makePoint rejects a disallowed operation', (t) {
      final ctx = base({
        'op': {'name': 'nope', 'points': []},
        'options': {
          'allow': {'op': 'load'}
        }
      });
      equal('point_op_allow', errcode(stdutil.makePoint(ctx)));
    });

    test('an allow list names whole operations, in any case', (t) {
      final op = {
        'name': 'load',
        'points': [
          {
            'method': 'GET',
            'parts': ['a']
          }
        ]
      };
      equal(
          'point_op_allow',
          errcode(stdutil.makePoint(base({
            'op': op,
            'options': {
              'allow': {'op': 'reload,unload'}
            }
          }))));
      final ctx = base({
        'op': op,
        'options': {
          'allow': {'op': 'list,\n LOAD'}
        }
      });
      equal(true, identical(stdutil.makePoint(ctx), ctx.op.points[0]));
    });

    test('an allow list names whole methods', (t) {
      final ctx = base({
        'op': {'name': 'update', 'points': []},
        'options': {
          'allow': {'method': 'GET,PUT'},
          'base': 'http://x'
        }
      });
      ctx.point = Point({
        'method': 'pu',
        'parts': ['a']
      });
      equal('spec_method_allow', errcode(stdutil.makeSpec(ctx)));
    });

    test('a patch, like an update, takes the request data as its input', (t) {
      equal('data', stdutil.makeContext({'opname': 'patch'}).op.input);
      equal('data', stdutil.makeContext({'opname': 'update'}).op.input);
      equal('match', stdutil.makeContext({'opname': 'load'}).op.input);
    });

    test('makePoint rejects an operation with no endpoints', (t) {
      final ctx = base({
        'op': {'name': 'load', 'points': []},
        'options': {'allow': allow}
      });
      equal('point_no_points', errcode(stdutil.makePoint(ctx)));
    });

    test('makePoint returns the single point', (t) {
      final ctx = base({
        'op': {
          'name': 'load',
          'points': [
            {
              'method': 'GET',
              'parts': ['a']
            }
          ]
        },
        'options': {'allow': allow}
      });
      final r = stdutil.makePoint(ctx);
      equal(true, identical(r, ctx.op.points[0]));
    });

    test('makePoint short-circuits a feature-supplied point', (t) {
      final preset = {'method': 'GET'};
      final ctx = base({
        'out': {'point': preset}
      });
      equal(true, identical(preset, stdutil.makePoint(ctx)));
    });

    test('makeSpec short-circuits a feature-supplied spec', (t) {
      final preset = {'method': 'GET'};
      final ctx = base({
        'out': {'spec': preset}
      });
      equal(true, identical(preset, stdutil.makeSpec(ctx)));
    });
  });

  describe('pipeline:prepare + direct', () {
    test('prepare sends a method allow.method names, in upper case', (t) async {
      final sdk = UnivecSDK.test({}, {
        'allow': {'method': 'PUT,\n get'}
      });
      final fetchdef = await sdk.prepare({'path': '/a', 'method': 'get'});
      equal('GET', fetchdef['method']);
      equal('spec_method_allow',
          errcode(await sdk.prepare({'path': '/a', 'method': 'POST'})));
      equal('spec_method_allow',
          errcode(await sdk.prepare({'path': '/a', 'method': 'PU'})));
    });

    test('prepare refuses every method under an empty allow.method',
        (t) async {
      final sdk = UnivecSDK.test({}, {
        'allow': {'method': ''}
      });
      equal('spec_method_allow',
          errcode(await sdk.prepare({'path': '/a', 'method': 'get'})));
    });

    test('a null allow, allow.op or allow.method takes the default',
        (t) async {
      for (final allow in <dynamic>[
        {'method': null},
        {'op': null},
        null
      ]) {
        final sdk = UnivecSDK.test({}, {'allow': allow});
        equal('GET,PUT,POST,PATCH,DELETE,OPTIONS',
            vs.getpath(sdk.options(), 'allow.method'));
        equal('create,update,patch,load,list,remove,command,direct,graphql',
            vs.getpath(sdk.options(), 'allow.op'));
        equal('POST',
            (await sdk.prepare({'path': '/a', 'method': 'post'}))['method']);
        equal('spec_method_allow',
            errcode(await sdk.prepare({'path': '/a', 'method': 'HEAD'})));
      }
    });

    test('a list the allow option omits takes the default', (t) async {
      final sdk = UnivecSDK.test({}, {'allow': {}});
      equal('GET,PUT,POST,PATCH,DELETE,OPTIONS',
          vs.getpath(sdk.options(), 'allow.method'));
      equal('create,update,patch,load,list,remove,command,direct,graphql',
          vs.getpath(sdk.options(), 'allow.op'));
      equal('spec_method_allow',
          errcode(await sdk.prepare({'path': '/a', 'method': 'HEAD'})));

      // The caller's allow replaces a config allow that is null or not a map.
      dynamic over(dynamic cfgallow, dynamic allow) =>
          stdutil.makeOptions(stdutil.makeContext({
            'utility': stdutil,
            'options': {'allow': allow},
            'config': {
              'options': {'allow': cfgallow}
            },
          }));
      for (final cfgallow in <dynamic>['x', null]) {
        final opts = over(cfgallow, {'op': 'load'});
        equal('GET,PUT,POST,PATCH,DELETE,OPTIONS',
            vs.getpath(opts, 'allow.method'));
        equal('load', vs.getpath(opts, 'allow.op'));
      }
      equal('create,update,patch,load,list,remove,command,direct,graphql',
          vs.getpath(over('x', {'method': 'GET'}), 'allow.op'));
    });

    test('one options map builds two clients, each over its own model', (t) {
      Map<String, dynamic> literal() => {
            'base': 'http://api.test',
            'allow': <String, dynamic>{'op': 'create,load,list'},
            'headers': <String, dynamic>{'x-caller': 'c1'},
            'entity': <String, dynamic>{
              'widget': <String, dynamic>{'note': 'c1'}
            },
          };
      // The constructor reads the generated config, so a client over the
      // model narrowed to GET is the makeOptions it runs, given that model.
      dynamic getOnly(dynamic options) =>
          stdutil.makeOptions(stdutil.makeContext({
            'utility': stdutil,
            'options': options,
            'config': {
              ...config.toMap(),
              'options': {
                ...config.options,
                'allow': {'method': 'GET'}
              },
            },
          }));
      final model = vs.clone(config.options);
      final shared = literal();
      UnivecSDK(shared);
      deepEqual(literal(), shared, 'the first client changed the options map');
      deepEqual(model, config.options, 'the first client changed the model');
      final second = getOnly(shared);
      deepEqual(getOnly(literal()), second, 'the second client');
      equal('GET', vs.getpath(second, 'allow.method'));
    });

    test('direct is refused by a list that names only indirect', (t) async {
      final sdk = UnivecSDK.test({}, {
        'allow': {'op': 'indirect,reload'}
      });
      final res = await sdk.direct({'path': '/a'});
      equal(false, res['ok']);
      ok(res['err'].toString().contains('not allowed by SDK option allow.op'));
    });

    test('direct answers a method allow.method refuses with a result map',
        (t) async {
      final sdk = UnivecSDK.test({}, {
        'allow': {'method': 'GET'}
      });
      final res = await sdk.direct({'path': '/a', 'method': 'POST'});
      equal(false, res['ok']);
      equal('spec_method_allow', errcode(res['err']));
    });

    test('direct reports a body the transport marks as not JSON', (t) async {
      final sdk = UnivecSDK({
        'base': 'http://nonjson.test',
        'apikey': 'NONJSON-SECRET-7f2c',
        'headers': {'user-agent': 'Probe/1.0'},
        'system': {
          'fetch': (dynamic url, dynamic fetchdef) => {
                'status': 200,
                'statusText': 'OK',
                'headers': {'content-type': 'text/html'},
                'body': '<html>key NONJSON-SECRET-7f2c ' + 'x' * 300 + '</html>',
                'json': () => null,
                'unreadable': true,
              }
        }
      });
      final res = await sdk.direct({'path': '/a'});
      equal(false, res['ok']);
      equal('response_content_type', errcode(res['err']));
      final String msg = res['err'].message;
      ok(msg.contains('expected JSON, got text/html (HTTP 200, '
          'content-type text/html, user-agent Probe/1.0, body: <html>key '));
      ok(!msg.contains('NONJSON-SECRET-7f2c'));
      ok(msg.endsWith('...)'));
    });
  });

  describe('pipeline:makeResponse', () {
    test('guards missing spec / response / result', (t) async {
      equal(
          'response_no_spec',
          errcode(await stdutil.makeResponse(
              base({'spec': null, 'response': {}, 'result': {}}))));
      equal(
          'response_no_response',
          errcode(await stdutil.makeResponse(
              base({'spec': {}, 'response': null, 'result': {}}))));
      equal(
          'response_no_result',
          errcode(await stdutil.makeResponse(
              base({'spec': {}, 'response': {}, 'result': null}))));
    });

    test('a 4xx response sets result.err and copies headers', (t) async {
      final ctx = base({
        'spec': {'step': 's'},
        'response': resp(404, null, {'x-a': '1'}),
        'result': {'ok': false}
      });
      await stdutil.makeResponse(ctx);
      ok(null != ctx.result.err);
      equal(404, ctx.result.status);
      equal('1', ctx.result.headers['x-a']);
    });

    test('a 2xx response parses the body and marks ok', (t) async {
      final ctx = base({
        'spec': {'step': 's'},
        'response': resp(200, {'v': 1}),
        'result': {'ok': false}
      });
      await stdutil.makeResponse(ctx);
      equal(true, ctx.result.ok);
      deepEqual(ctx.result.body, {'v': 1});
    });

    test('records to ctrl.explain when explain is on', (t) async {
      final ctx = base({
        'ctrl': {'explain': {}},
        'spec': {'step': 's'},
        'response': resp(200, {'v': 2}),
        'result': {'ok': false}
      });
      await stdutil.makeResponse(ctx);
      ok(null != ctx.ctrl['explain']['result']);
    });

    test('a body marked as not JSON is named by its label', (t) async {
      Future<dynamic> run(int status, String? type, String body) async {
        final r = resp(status, null,
            null == type ? null : <String, dynamic>{'content-type': type});
        r['body'] = body;
        r['unreadable'] = true;
        final ctx = base({
          'spec': {
            'step': 's',
            'headers': {'user-agent': 'Probe/1.0'}
          },
          'response': r,
          'result': {'ok': false}
        });
        await stdutil.makeResponse(ctx);
        return ctx.result.err;
      }

      final bad = await run(200, 'application/json', '{"a": ');
      equal('response_json_invalid', bad.code);
      ok(bad.message.contains('body is not valid JSON (HTTP 200, '
          'content-type application/json, user-agent Probe/1.0, body: {"a":)'));
      final untyped = await run(200, null, 'not json');
      equal('response_json_invalid', untyped.code);
      ok(untyped.message.contains('content-type none'));
      final html = await run(200, 'text/html', '<p>\n  challenge </p>');
      equal('response_content_type', html.code);
      ok(html.message.contains('expected JSON, got text/html'));
      ok(html.message.contains('body: <p> challenge </p>)'));
      final failed = await run(503, 'text/html', '<p>down</p>');
      equal('request_status', failed.code);
      ok(failed.message.contains('request: 503: ERR (HTTP 503, '
          'content-type text/html, user-agent Probe/1.0, body: <p>down</p>)'));
    });

    test('a body-parse exception is captured on result.err', (t) async {
      final throwing = resp(200, null);
      throwing['json'] = () => throw StateError('bad json');
      final ctx = base({
        'spec': {'step': 's'},
        'response': throwing,
        'result': {'ok': false}
      });
      await stdutil.makeResponse(ctx);
      ok(null != ctx.result.err);
    });

    test('short-circuits when a feature already supplied the response',
        (t) async {
      final preset = resp(299);
      final ctx = base({
        'out': {'response': preset},
        'spec': {},
        'response': {},
        'result': {}
      });
      equal(true, identical(preset, await stdutil.makeResponse(ctx)));
    });
  });

  describe('pipeline:makeResult', () {
    test('guards missing spec / result', (t) {
      equal('result_no_spec',
          errcode(stdutil.makeResult(base({'spec': null, 'result': {}}))));
      equal('result_no_result',
          errcode(stdutil.makeResult(base({'spec': {}, 'result': null}))));
    });

    test('list op wraps resdata into entity instances', (t) {
      final made = [];
      final ctx = base({
        'op': {'name': 'list', 'entity': 'x'},
        'entity': _FakeEnt(made),
        'spec': {'step': 's'},
        'result': {
          'resdata': [
            {'a': 1},
            {'a': 2}
          ]
        },
      });
      final r = stdutil.makeResult(ctx);
      equal(2, r.resdata.length);
      equal(2, made.length);
    });

    test('an empty list yields an empty resdata array', (t) {
      final ctx = base({
        'op': {'name': 'list', 'entity': 'x'},
        'entity': _FakeEnt([]),
        'spec': {'step': 's'},
        'result': {'resdata': []},
      });
      final r = stdutil.makeResult(ctx);
      deepEqual(r.resdata, []);
    });

    test('short-circuits on a preset result', (t) {
      final preset = {'ok': true};
      equal(
          true,
          identical(
              preset,
              stdutil.makeResult(base({
                'out': {'result': preset},
                'spec': {},
                'result': {}
              }))));
    });
  });

  describe('pipeline:makeRequest', () {
    test('guards a missing spec', (t) async {
      equal('request_no_spec',
          errcode(await stdutil.makeRequest(base({'spec': null}))));
    });

    test('a null transport result becomes a response error', (t) async {
      final ctx = base({
        'utility': utilWith((c, u, f) async => null),
        'spec': {'step': 's', 'method': 'GET', 'headers': {}}
      });
      final r = await stdutil.makeRequest(ctx);
      ok(null != r.err);
    });

    test('an Error transport result is carried on the response', (t) async {
      final boom = UnivecError('boom', 'boom', null);
      final ctx = base({
        'utility': utilWith((c, u, f) async => boom),
        'spec': {'step': 's', 'method': 'GET', 'headers': {}}
      });
      final r = await stdutil.makeRequest(ctx);
      equal(true, identical(boom, r.err));
    });

    test('a normal transport response is wrapped', (t) async {
      final ctx = base({
        'utility': utilWith((c, u, f) async => resp(200, {'a': 1})),
        'spec': {'step': 's', 'method': 'GET', 'headers': {}}
      });
      final r = await stdutil.makeRequest(ctx);
      equal(200, r.status);
    });

    test('records the fetchdef to ctrl.explain', (t) async {
      final ctx = base({
        'ctrl': {'explain': {}},
        'utility': utilWith((c, u, f) async => resp(200, {})),
        'spec': {'step': 's', 'method': 'GET', 'headers': {}},
      });
      await stdutil.makeRequest(ctx);
      ok(null != ctx.ctrl['explain']['fetchdef']);
    });

    test('a fetchdef error surfaces as a response error', (t) async {
      final u = Utility();
      u.makeFetchDef = (dynamic c) => UnivecError('fetchdef_boom', 'boom', null);
      final ctx = base({
        'utility': u,
        'spec': {'step': 's', 'method': 'GET', 'headers': {}}
      });
      final r = await stdutil.makeRequest(ctx);
      ok(null != r.err);
    });

    test('short-circuits a feature-supplied request', (t) async {
      final preset = resp(201);
      equal(
          true,
          identical(
              preset,
              await stdutil.makeRequest(base({
                'out': {'request': preset},
                'spec': {}
              }))));
    });
  });

  describe('pipeline:makeFetchDef', () {
    test('guards a missing spec', (t) {
      equal('fetchdef_no_spec',
          errcode(stdutil.makeFetchDef(base({'spec': null}))));
    });

    test('serialises an object body to JSON and inits a missing result', (t) {
      final ctx = base({
        'result': null,
        'spec': {
          'step': 's',
          'method': 'POST',
          'headers': {},
          'base': 'http://h',
          'prefix': '',
          'suffix': '',
          'parts': ['a'],
          'path': 'a',
          'body': {'x': 1}
        },
      });
      final fd = stdutil.makeFetchDef(ctx);
      ok(fd['body'] is String);
      ok(fd['url'].toString().contains('http://h'));
      ok(null != ctx.result); // result was lazily created
    });
  });

  describe('pipeline:makeError + done', () {
    test('done returns resdata on success', (t) {
      equal(
          42,
          stdutil.done(base({
            'result': {'ok': true, 'resdata': 42}
          })));
    });

    test('done throws the error when not ok', (t) {
      var threw = false;
      try {
        stdutil.done(base({
          'result': {'ok': false}
        }));
      } catch (_e) {
        threw = true;
      }
      equal(true, threw);
    });

    test('done cleans ctrl.explain on success', (t) {
      final ctx = base({
        'ctrl': {
          'explain': {
            'result': {'err': 'x'}
          }
        },
        'result': {'ok': true, 'resdata': 7}
      });
      equal(7, stdutil.done(ctx));
    });

    test('makeError returns resdata instead of throwing when ctrl.throw is false',
        (t) {
      final ctx = base({
        'ctrl': {'throw': false},
        'result': {'ok': false, 'resdata': 'fallback'}
      });
      equal('fallback', stdutil.makeError(ctx));
    });

    test('makeError records to ctrl.explain', (t) {
      final ctx = base({
        'ctrl': {'throw': false, 'explain': {}},
        'result': {'ok': false}
      });
      stdutil.makeError(ctx);
      ok(null != ctx.ctrl['explain']['err']);
    });
  });

  describe('pipeline:featureAdd ordering', () {
    _FeatClient client() =>
        _FeatClient()..features = [_feat('a'), _feat('b')];

    String names(_FeatClient c) =>
        c.features.map((f) => (f as dynamic).name).join(',');

    test('appends by default', (t) {
      final c = client();
      stdutil.featureAdd(base({'client': c}), _feat('z'));
      equal('a,b,z', names(c));
    });

    test('__before__ inserts ahead of the named feature', (t) {
      final c = client();
      stdutil.featureAdd(
          base({'client': c}), _feat('z', {'__before__': 'b'}));
      equal('a,z,b', names(c));
    });

    test('__after__ inserts behind the named feature', (t) {
      final c = client();
      stdutil.featureAdd(base({'client': c}), _feat('z', {'__after__': 'a'}));
      equal('a,z,b', names(c));
    });

    test('__replace__ swaps the named feature', (t) {
      final c = client();
      stdutil.featureAdd(
          base({'client': c}), _feat('z', {'__replace__': 'a'}));
      equal('z,b', names(c));
    });
  });

  describe('pipeline:feature order', () {
    dynamic resolve(dynamic feature) {
      final ctx = stdutil.makeContext({
        'utility': stdutil,
        'options': {'feature': feature},
        'config': {'options': {}},
      });
      return stdutil.makeOptions(ctx);
    }

    test('map form is ordered test-first (test is the base transport)', (t) {
      final o = resolve({
        'metrics': {'active': true},
        'test': {'active': true}
      });
      equal('test,metrics',
          (o['__derived__']['featureorder'] as List).join(','));
    });

    test('array form preserves the explicit developer-specified order', (t) {
      final o = resolve([
        {'name': 'metrics', 'active': true},
        {'name': 'test', 'active': true}
      ]);
      equal('metrics,test',
          (o['__derived__']['featureorder'] as List).join(','));
      // the List is normalized to a map for merge/init, opts preserved
      equal(true, o['feature']['metrics']['active']);
      equal(true, o['feature']['test']['active']);
    });

    test('map form with no test orders names deterministically', (t) {
      final o = resolve({
        'retry': {'active': true},
        'cache': {'active': true}
      });
      equal('cache,retry',
          (o['__derived__']['featureorder'] as List).join(','));
    });
  });

  describe('pipeline:prepareAuth', () {
    // Fake client so the exact options.auth / apikey shape is controlled.
    dynamic authCtx(dynamic options, dynamic headers) {
      return base({
        'client': _OptClient(options),
        'spec': null == headers ? null : {'headers': headers}
      });
    }

    test('guards a missing spec', (t) {
      equal(
          'auth_no_spec',
          errcode(stdutil.prepareAuth(authCtx({
            'auth': {'prefix': ''},
            'apikey': 'K'
          }, null))));
    });

    test('an apikey with a prefix is space-joined', (t) {
      final ctx = authCtx({
        'apikey': 'K',
        'auth': {'prefix': 'Bearer'}
      }, {});
      stdutil.prepareAuth(ctx);
      equal('Bearer K', ctx.spec.headers['authorization']);
    });

    test('a raw apikey (empty prefix) goes in as-is', (t) {
      final ctx = authCtx({
        'apikey': 'K',
        'auth': {'prefix': ''}
      }, {});
      stdutil.prepareAuth(ctx);
      equal('K', ctx.spec.headers['authorization']);
    });

    test('an empty apikey drops the header', (t) {
      final ctx = authCtx({
        'apikey': '',
        'auth': {'prefix': 'Bearer'}
      }, {
        'authorization': 'stale'
      });
      stdutil.prepareAuth(ctx);
      equal(null, ctx.spec.headers['authorization']);
    });

    test('a public API (no auth block) drops the header', (t) {
      final ctx = authCtx({'apikey': 'K'}, {'authorization': 'stale'});
      stdutil.prepareAuth(ctx);
      equal(null, ctx.spec.headers['authorization']);
    });

    test('a missing apikey option drops the header', (t) {
      final ctx = authCtx({
        'auth': {'prefix': 'Bearer'}
      }, {
        'authorization': 'stale'
      });
      stdutil.prepareAuth(ctx);
      equal(null, ctx.spec.headers['authorization']);
    });
  });

  describe('pipeline:result helpers', () {
    test('resultHeaders with a plain map copies entries', (t) {
      final ctx = base({
        'response': {'headers': {}},
        'result': {}
      });
      stdutil.resultHeaders(ctx);
      deepEqual(ctx.result.headers, {});
    });

    test('resultBody skips parsing when the body is absent', (t) async {
      final ctx = base({
        'response': {
          'json': () => {'a': 1},
          'body': null
        },
        'result': {}
      });
      await stdutil.resultBody(ctx);
      equal(null, ctx.result.body);
    });
  });

  // A header, cookie or query argument travels where the definition declares
  // it. Port of the ts pathquery.test.ts cases.
  describe('pipeline:prepareHeaders + prepareQuery + transformRequest', () {
    dynamic hctx(Map<String, dynamic> point, Map<String, dynamic> reqmatch,
        Map<String, dynamic> reqdata,
        [Map<String, dynamic>? headers]) {
      final ctx = stdutil.makeContext({
        'point': point,
        'reqmatch': reqmatch,
        'reqdata': reqdata,
      });
      ctx.utility = stdutil;
      ctx.client = _OptClient({'headers': headers ?? <String, dynamic>{}});
      return ctx;
    }

    final headerPoint = <String, dynamic>{
      'args': {
        'header': [
          {'name': 'idempotency_key', 'orig': 'Idempotency-Key', 'kind': 'header'},
          {'name': 'x_trace', 'orig': 'X-Trace', 'kind': 'header'},
          {'name': 'page_size', 'orig': 'Page-Size', 'kind': 'header'},
        ]
      }
    };

    test('a header argument from the match goes out under its orig', (t) {
      deepEqual({'user-agent': 'sdk', 'idempotency-key': 'k1', 'page-size': '3'},
          stdutil.prepareHeaders(hctx(headerPoint,
              {'idempotency_key': 'k1', 'page_size': 3}, {}, {'user-agent': 'sdk'})));
    });

    test('a header argument from the data goes out too', (t) {
      deepEqual({'x-trace': 't1'},
          stdutil.prepareHeaders(hctx(headerPoint, {}, {'x_trace': 't1', 'name': 'n'})));
    });

    test('an absent or null header argument is not sent', (t) {
      deepEqual({}, stdutil.prepareHeaders(hctx(headerPoint, {'idempotency_key': null}, {})));
    });

    test('a header argument replaces a default of the same name in any case', (t) {
      deepEqual({'user-agent': 'sdk', 'idempotency-key': 'call'},
          stdutil.prepareHeaders(hctx(headerPoint, {'idempotency_key': 'call'}, {},
              {'Idempotency-Key': 'default', 'user-agent': 'sdk'})));
    });

    final cookiePoint = <String, dynamic>{
      'args': {
        'header': [
          {'name': 'x_trace', 'orig': 'X-Trace', 'kind': 'header'}
        ],
        'cookie': [
          {'name': 'session_id', 'orig': 'SESSIONID', 'kind': 'cookie'},
          {'name': 'theme', 'orig': 'theme', 'kind': 'cookie'},
          {'name': 'prefs', 'orig': 'prefs', 'kind': 'cookie'},
        ],
      }
    };

    test('a cookie argument goes out in the cookie header as name=value', (t) {
      deepEqual({'cookie': 'SESSIONID=s1; theme=dark'},
          stdutil.prepareHeaders(hctx(cookiePoint, {'session_id': 's1'},
              {'theme': 'dark', 'name': 'n'})));
    });

    test('a cookie argument follows the cookies the caller sends, whatever the header case', (t) {
      deepEqual({'user-agent': 'sdk', 'cookie': 'lang=en; SESSIONID=s1'},
          stdutil.prepareHeaders(hctx(cookiePoint, {'session_id': 's1'}, {},
              {'Cookie': 'lang=en', 'user-agent': 'sdk'})));
    });

    test('an absent or null cookie argument leaves the headers alone', (t) {
      deepEqual({'Cookie': 'lang=en'},
          stdutil.prepareHeaders(hctx(cookiePoint, {'session_id': null}, {},
              {'Cookie': 'lang=en'})));
    });

    test('a cookie argument is form serialized and percent-encoded', (t) {
      deepEqual({'cookie': 'SESSIONID=a%20b%3Bc%2Cd; theme=dark; theme=x%20y; lang=en%20gb; size=2'},
          stdutil.prepareHeaders(hctx(cookiePoint, {'session_id': 'a b;c,d'},
              {'theme': ['dark', 'x y'], 'prefs': {'size': 2, 'lang': 'en gb'}})));
    });

    test('a cookie argument replaces a cookie of the same name the caller sends', (t) {
      deepEqual({'cookie': 'theme=dark; lang=en; SESSIONID=s1'},
          stdutil.prepareHeaders(hctx(cookiePoint, {'session_id': 's1'}, {},
              {'Cookie': 'SESSIONID=old; theme=dark ;lang=en'})));
    });

    test('a map cookie argument replaces the cookies its keys name, in their encoded form', (t) {
      deepEqual({'cookie': 'theme=dark; SESSIONID=s1; lang=en; size=2'},
          stdutil.prepareHeaders(hctx(cookiePoint, {'session_id': 's1'},
              {'prefs': {'lang': 'en', 'size': 2}}, {'Cookie': 'lang=old; theme=dark'})));
      deepEqual({'cookie': 'theme=dark; SESSIONID=s1; x%20y=new'},
          stdutil.prepareHeaders(hctx(cookiePoint, {'session_id': 's1'},
              {'prefs': {'x y': 'new'}}, {'Cookie': 'x%20y=old; theme=dark'})));
    });

    test('a default cookie whose value holds pairs is kept whole', (t) {
      deepEqual({'cookie': 'session=a=b&theme=old; SESSIONID=s1; theme=dark'},
          stdutil.prepareHeaders(hctx(cookiePoint, {'session_id': 's1'},
              {'theme': 'dark'}, {'Cookie': 'session=a=b&theme=old'})));
    });

    test('the declared response media is asked for, unless the caller set an accept', (t) {
      final media = <String, dynamic>{
        'response': {'kind': 'json', 'media': 'application/vnd.api+json'},
        'body': {'kind': 'json', 'media': 'application/vnd.api+json'},
      };
      deepEqual({'accept': 'application/vnd.api+json', 'content-type': 'application/vnd.api+json'},
          stdutil.prepareHeaders(hctx(media, {}, {}, {'content-type': 'application/json'})));
      deepEqual({'Accept': 'text/plain', 'content-type': 'text/plain'},
          stdutil.prepareHeaders(hctx(media, {}, {},
              {'Accept': 'text/plain', 'content-type': 'text/plain'})));
    });

    final queryPoint = <String, dynamic>{
      'params': ['id'],
      'transform': {'req': '`reqdata`'},
      'args': {
        'params': [
          {'name': 'id'}
        ],
        'query': [
          {'name': 'page_size', 'orig': 'pageSize', 'kind': 'query'},
          {'name': 'lang', 'orig': 'lang', 'kind': 'query'},
          {'name': 'trace', 'orig': 'trace', 'kind': 'query'},
        ],
        'header': [
          {'name': 'x_trace', 'orig': 'X-Trace', 'kind': 'header'},
          {'name': 'trace', 'orig': 'trace', 'kind': 'header'},
        ],
        'cookie': [
          {'name': 'session_id', 'orig': 'SESSIONID', 'kind': 'cookie'},
          {'name': 'lang', 'orig': 'lang', 'kind': 'cookie'},
        ],
      }
    };

    test('a path, header or cookie argument stays out of the query', (t) {
      deepEqual({'q': 'x'},
          stdutil.prepareQuery(hctx(queryPoint,
              {'id': 'i1', 'x_trace': 't1', 'session_id': 's1', 'q': 'x', r'$action': 'a'}, {})));
    });

    test('a query argument goes out under its orig, from the match or the data', (t) {
      deepEqual({'pageSize': 3, 'lang': 'en'},
          stdutil.prepareQuery(hctx(queryPoint, {'page_size': 3}, {'lang': 'en'})));
    });

    test('a query argument that shares a header or cookie name still goes out', (t) {
      deepEqual({'lang': 'en', 'trace': 't1'},
          stdutil.prepareQuery(hctx(queryPoint, {'lang': 'en', 'trace': 't1'}, {})));
    });

    test('a routed argument is left out of the body', (t) {
      deepEqual({'title': 'T'},
          stdutil.transformRequest(hctx(queryPoint, {},
              {'x_trace': 't1', 'session_id': 's1', 'page_size': 2, 'title': 'T', r'$action': 'a'})));
    });

    test('an argument the point marks as a field the body keeps stays in the body', (t) {
      for (final kind in ['header', 'cookie', 'query']) {
        final point = <String, dynamic>{
          'transform': {'req': '`reqdata`'},
          'args': {
            kind: [
              {'name': 'locale', 'orig': 'Locale', 'field': true},
              {'name': 'session_id', 'orig': 'SESSIONID'},
            ],
          },
        };
        deepEqual({'name': 'n', 'locale': 'en'},
            stdutil.transformRequest(
                hctx(point, {}, {'name': 'n', 'locale': 'en', 'session_id': 's1'})));
      }
    });

    test('a raw request body is sent as given', (t) {
      final ctx = hctx(<String, dynamic>{
        'body': {'kind': 'raw', 'media': 'text/plain'},
      }, {}, {r'$body': 'hello'});
      ctx.op = Operation({'name': 'create', 'entity': 'x', 'input': 'data'});
      equal('hello', stdutil.prepareBody(ctx));
    });
  });

  describe('fetcher:httpFetch', () {
    test('marks a body that is not JSON and sends the default agent', (t) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        final agent = req.headers.value('user-agent') ?? '';
        if ('/json' == req.uri.path) {
          req.response.headers.contentType = ContentType.json;
          req.response.write('{"agent": "$agent"}');
        } else if ('/page' == req.uri.path) {
          req.response.headers.contentType = ContentType.html;
          req.response.write('<p>$agent</p>');
        }
        req.response.close();
      });
      try {
        final url = 'http://127.0.0.1:${server.port}';
        equal('Mozilla/5.0 (compatible; UnivecSDK/1.0)', defaultUserAgent);

        final sent = <String, dynamic>{};
        final page = await httpFetch('$url/page', {'method': 'GET', 'headers': sent});
        equal(true, page['unreadable']);
        equal('<p>$defaultUserAgent</p>', page['body']);
        equal(defaultUserAgent, sent['user-agent']);

        final bare = <String, dynamic>{'method': 'GET'};
        final blank = await httpFetch('$url/blank', bare);
        equal(false, blank['unreadable']);
        equal(null, blank['body']);
        equal(defaultUserAgent, bare['headers']['user-agent']);

        final own = <String, dynamic>{'User-Agent': 'Probe/1.0'};
        final data = await httpFetch('$url/json', {'method': 'GET', 'headers': own});
        equal(false, data['unreadable']);
        equal('Probe/1.0', data['json']()['agent']);
        equal(1, own.length);
      } finally {
        await server.close(force: true);
      }
    });
  });

  describe('feature:test mock envelope', () {
    test('a list whose items each wrap the record answers the wrappers', (t) {
      final spec = [r'`$EACH`', 'body', {r'`$MERGE`': '`.badge`'}];
      final out = mockEnvelope(spec, [{'id': 'b1'}, {'id': 'b2'}]);
      deepEqual([{'badge': {'id': 'b1'}}, {'badge': {'id': 'b2'}}], out);
      deepEqual([{'id': 'b1'}, {'id': 'b2'}], vs.transform({'body': out}, spec));
    });
  });
}
