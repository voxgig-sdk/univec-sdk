// Behavioural tests for the secrets feature (vendored @voxgig/sekreto).
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because SecretsFeature places it FIRST in the provider
// chain (a `memory` store named `options`) - explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic. With
// the option unset, the chain (memory, env, dotenv, a vault) supplies the
// credential instead. And a broken store FAILS the operation rather than
// quietly sending it unauthenticated.
//
// WHERE THESE TESTS OBSERVE, AND WHY IT MATTERS.
//
// The dart port resolves at the TRANSPORT SEAM and holds the credential in
// feature state, so the only honest place to assert is the transport - what
// actually reached the wire, and how many times. Two seams are used, and
// each one is REAL in its leg:
//
//   * A LIVE UnivecSDK with `system.fetch` injected. Nothing replaces
//     that function, so a counter hung off it counts wire attempts. This is
//     the RAW path (direct/graphql), which runs no feature hooks at all.
//   * The offline feature harness, whose `server` is installed as
//     `utility.fetcher` BEFORE features initialise - so SecretsFeature
//     wraps it and the server is genuinely the inner transport. This is the
//     ENTITY path, through the hook pipeline.
//
// What is deliberately NOT used for a fail-closed assertion: `SDK.test()`
// with `prepare()`. Test mode REPLACES the transport with its own mock and
// prepare() never reaches one at all, so "no request was sent" holds for a
// healthy SDK carrying no secrets feature whatsoever - an assertion that
// cannot fail pins no rule. Every refusal below is therefore paired with a
// CONTROL leg: the same construction with a WORKING provider, which must
// reach the SAME transport exactly once, carrying the credential. Only then
// does a zero mean REFUSED rather than UNWIRED. And each failure is matched
// on the PROVIDER'S OWN message, so an unrelated error (a blocked op, a bad
// URL) cannot stand in for fail-closed.
//
// This file lives in the `feature/` container on purpose: `target add`
// trims it, along with the feature source and the vendored library, for a
// project whose model does not select `secrets`.

import 'dart:async';

import '../../harness.dart';
import '../harness.dart' as fh;

import '../../../lib/UnivecSDK.dart' show UnivecSDK;
import '../../../lib/Config.dart' show FEATURE_PLUGINS;
import '../../../lib/feature/secrets/sekreto/src/provider.dart';
import '../../../lib/feature/secrets/sekreto/src/sekreto.dart' show SekretoError;


const String RAWBASE = 'http://raw.test/api';
const String EXBASE = 'http://exchange.test/api';
const String REFRESH = 'REFRESH01';


// The Authorization header carries the SPEC's credential prefix, which a
// TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives
// `Bearer <token>`, an apiKey scheme the raw token. So assert on the
// CREDENTIAL and let the prefix be whatever this SDK's API declares -
// pinning the whole header value passes only for a prefix-less API, and
// this file ships to every project that selects the feature.
void credentialIs(dynamic header, String token) {
  final got = null == header ? '' : '$header';
  ok(got == token || got.endsWith(' $token'),
      'expected the Authorization header to carry $token, got: "$got"');
}


// A store that HAS the secret. The chain's ordinary case.
class GoodProvider extends Provider {
  final String value;
  int asked = 0;
  final List<String> names = [];

  GoodProvider([this.value = 'RAWKEY01']);

  @override
  FutureOr<String?> lookup(String name) {
    asked++;
    names.add(name);
    return 'apikey' == name ? value : null;
  }

  @override
  String describe() => 'working:test';
}


// A store that could not ANSWER - the case that must never degrade into an
// unauthenticated request. Distinct from a store that simply lacks the
// secret, which is a MISS and lets the chain carry on.
class BrokenProvider extends Provider {
  int asked = 0;

  @override
  FutureOr<String?> lookup(String _name) {
    asked++;
    throw SekretoError('vault unreachable');
  }

  @override
  String describe() => 'broken:test';
}


// A store that has nothing. Not an error.
class EmptyProvider extends Provider {
  @override
  FutureOr<String?> lookup(String _name) => null;

  @override
  String describe() => 'empty:test';
}


// Fails once, then recovers - a transient vault outage.
class FlakyProvider extends Provider {
  int asked = 0;

  @override
  FutureOr<String?> lookup(String _name) {
    asked++;
    if (1 == asked) {
      throw SekretoError('vault unreachable');
    }
    return 'RECOVERED01';
  }

  @override
  String describe() => 'flaky:test';
}


// Counts every lookup, answering with a different value each time, so
// `cache: false` can be told from `cache: true`.
class CountingProvider extends Provider {
  int asked = 0;

  @override
  FutureOr<String?> lookup(String _name) {
    asked++;
    return 'KEY$asked';
  }

  @override
  String describe() => 'counting:test';
}


// A transport that records every call it is handed, so "sent" is a fact
// about the wire rather than about a mock. Doubles as the token endpoint
// for the exchange tests: `apiStatus` is a SCRIPT - one status per API
// call, the last repeating - so a case can say "401 then 200" without
// counting calls itself.
class Wire {
  final List<int> apiStatus;
  final List<String> tokens;
  final String tokenPath;
  final String responseField;
  final bool tokenFails;

  final List<Map<String, dynamic>> calls = [];
  int _issued = 0;
  int _apicall = -1;

  Wire({
    List<int>? apiStatus,
    List<String>? tokens,
    String? tokenPath,
    String? responseField,
    bool? tokenFails,
  })  : apiStatus = apiStatus ?? const [200],
        tokens = tokens ?? const ['ACCESS01', 'ACCESS02', 'ACCESS03'],
        tokenPath = tokenPath ?? 'auth/token',
        responseField = responseField ?? 'access_token',
        tokenFails = tokenFails ?? false;

  Future<dynamic> fetch(dynamic url, dynamic fetchdef) async {
    final headers = fetchdef is Map ? fetchdef['headers'] : null;

    calls.add(<String, dynamic>{
      'url': '$url',
      'fetchdef': fetchdef,
      'auth': headers is Map ? headers['authorization'] : null,
      'body': fetchdef is Map ? fetchdef['body'] : null,
    });

    if (_istoken('$url')) {
      if (tokenFails) {
        return <String, dynamic>{
          'status': 500,
          'json': () => <String, dynamic>{},
          'headers': <String, dynamic>{},
        };
      }
      final at = _issued < tokens.length ? _issued : tokens.length - 1;
      _issued++;
      return <String, dynamic>{
        'status': 200,
        'json': () => <String, dynamic>{responseField: tokens[at]},
        'headers': <String, dynamic>{},
      };
    }

    _apicall++;
    final at = _apicall < apiStatus.length ? _apicall : apiStatus.length - 1;
    final status = apiStatus[at];
    return <String, dynamic>{
      'status': status,
      'json': () => <String, dynamic>{'ok': 400 > status},
      'headers': <String, dynamic>{},
    };
  }

  bool _istoken(String url) => url.endsWith('/$tokenPath');

  int get sent => calls.length;

  List<Map<String, dynamic>> api() =>
      calls.where((c) => !_istoken('${c['url']}')).toList();

  List<Map<String, dynamic>> token() =>
      calls.where((c) => _istoken('${c['url']}')).toList();

  // What went out, for a failure message that names the leak rather than
  // just its count.
  String leak() =>
      calls.map((c) => '${c['url']} auth=${c['auth']}').join(', ');
}


// A LIVE client on the raw path. `allow.op` is named explicitly: a project
// that narrows the default set would otherwise turn the control leg into a
// false RED (refused before it reached the transport), and the rule under
// test lives downstream of the allow gate either way.
UnivecSDK rawSdk(Wire wire, List<dynamic> providers,
    [Map<String, dynamic>? extra]) {
  final secrets = <String, dynamic>{'active': true, 'providers': providers};
  if (null != extra) {
    extra.forEach((k, v) => secrets[k] = v);
  }

  final opts = <String, dynamic>{
    'base': RAWBASE,
    'allow': <String, dynamic>{'op': 'direct,graphql'},
    'system': <String, dynamic>{'fetch': wire.fetch},
    'feature': <String, dynamic>{'secrets': secrets},
  };

  return UnivecSDK(opts);
}


// The feature instance itself, for the credential the transport injects -
// this feature never writes the options map, so there is nothing to read
// there.
dynamic secretsOf(dynamic sdk) {
  for (final f in sdk.features) {
    if ('secrets' == f.name) {
      return f;
    }
  }
  return null;
}


// The ENTITY path: the offline harness pipeline (PrePoint, PreSpec,
// makeSpec, makeRequest, the transport), with `server` as the real inner
// transport SecretsFeature wraps.
class Entity {
  final List<Map<String, dynamic>> calls = [];
  late fh.Harness harness;

  int get sent => calls.length;

  dynamic auth(int i) {
    final headers = calls[i]['fetchdef']['headers'];
    return headers is Map ? headers['authorization'] : null;
  }

  String leak() =>
      calls.map((c) => '${c['url']} auth=${c['fetchdef']['headers']}').join(', ');
}


Entity entitySdk(List<dynamic> providers, [Map<String, dynamic>? options]) {
  final out = Entity();

  out.harness = fh.makeClient(
    features: [
      <String, dynamic>{
        'name': 'secrets',
        'options': <String, dynamic>{'active': true, 'providers': providers},
      }
    ],
    options: options,
    server: (dynamic _ctx, dynamic url, dynamic fetchdef) {
      out.calls.add(<String, dynamic>{'url': url, 'fetchdef': fetchdef});
      return fh.makeResponse(200, <String, dynamic>{'ok': true});
    },
  );

  return out;
}


void tests() {
  describe('secrets', () {

    // THE SUITE IS NOT VACUOUS. Test_dart registers this file only when the
    // model selects the feature, so a run that gets here with no secrets
    // feature is a wiring failure, not a skip - and every assertion below
    // would otherwise pass for the wrong reason.
    test('the secrets feature is present in this SDK', (t) {
      equal(true, fh.hasFeature('secrets'),
          'the secrets suite ran against an SDK with no secrets feature');
    });


    // --- the chain --------------------------------------------------------

    test('an explicit apikey wins over the chain', (t) async {
      // The explicit option seats FIRST as a `memory` store named
      // 'options', so it wins by sekreto's own first-hit rule rather than
      // by any special case in this feature.
      final wire = Wire();
      final chain = GoodProvider('CHAINKEY01');
      final sdk = UnivecSDK(<String, dynamic>{
        'base': RAWBASE,
        'apikey': 'OPTKEY01',
        'allow': <String, dynamic>{'op': 'direct,graphql'},
        'system': <String, dynamic>{'fetch': wire.fetch},
        'feature': <String, dynamic>{
          'secrets': <String, dynamic>{
            'active': true,
            'providers': [chain],
          }
        },
      });

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(1, wire.sent, 'the request never reached the transport');
      credentialIs(wire.calls[0]['auth'], 'OPTKEY01');
      equal(0, chain.asked,
          'first-hit means the chain behind the explicit option is not '
          'even asked');

      // The explicit option is a real store, not a special case: a directed
      // read names it like any other.
      equal('OPTKEY01', await sdk.secrets().getfrom('options', 'apikey'));
    });


    test('an omitted apikey defers to the chain', (t) async {
      final wire = Wire();
      final sdk = rawSdk(wire, [GoodProvider('CHAINKEY01')]);

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(1, wire.sent);
      credentialIs(wire.calls[0]['auth'], 'CHAINKEY01');

      // The credential lives in FEATURE STATE, and the shared options map
      // is left exactly as makeOptions built it.
      equal('CHAINKEY01', secretsOf(sdk).credential);
      equal('', sdk.options()['apikey'],
          'the feature wrote the shared options map');
    });


    test('a declarative provider MAP is accepted, not only an object',
        (t) async {
      // The shape a config file and the docs use. sekreto's dart
      // constructor takes only a ProviderSpec or a Provider, so the feature
      // has to convert - and a silent failure here means an SDK with an
      // EMPTY chain that quietly sends nothing.
      final wire = Wire();
      final sdk = rawSdk(wire, [
        <String, dynamic>{
          'kind': 'memory',
          'values': <String, String>{'APIKEY': 'MAPKEY01'},
        }
      ]);

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(1, wire.sent);
      credentialIs(wire.calls[0]['auth'], 'MAPKEY01');
    });


    test('a custom provider object is used verbatim', (t) async {
      final wire = Wire();
      final provider = GoodProvider('CUSTOM01');
      final sdk = rawSdk(wire, [provider]);

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      credentialIs(wire.calls[0]['auth'], 'CUSTOM01');
      deepEqual(['apikey'], provider.names,
          'the chain asked for something other than the configured name');
    });


    test('the secret name is configurable', (t) async {
      final wire = Wire();
      final sdk = rawSdk(wire, [
        <String, dynamic>{
          'kind': 'memory',
          'values': <String, String>{'API_TOKEN': 'TOKKEY01'},
        }
      ], <String, dynamic>{'name': 'api.token'});

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      credentialIs(wire.calls[0]['auth'], 'TOKKEY01');
    });


    test('a miss everywhere sends the request with NO credential', (t) async {
      // A store that does not hold the secret is a MISS, and the operation
      // proceeds - unauthenticated. That is the whole difference from the
      // error case below.
      final wire = Wire();
      final sdk = rawSdk(wire, [EmptyProvider()]);

      final res = await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(1, wire.sent, 'a miss must not block the request');
      equal(null, wire.calls[0]['auth']);
      equal(true, res['ok']);
    });


    test('sekreto is live for arbitrary secrets and redaction', (t) async {
      final wire = Wire();
      final sdk = rawSdk(wire, [
        <String, dynamic>{
          'kind': 'memory',
          'values': <String, String>{'DB_PASSWORD': 'dbpass01'},
        }
      ]);

      final secrets = sdk.secrets();
      equal('dbpass01', await secrets.get('db.password'));
      equal('the password is [redacted], keep it safe',
          secrets.redact('the password is dbpass01, keep it safe'));
    });


    // THE PROVIDER VOCABULARY. Upstream sekreto has no registry any more: a
    // kind not handed in through `plugins` is unknown to that Sekreto. So
    // the model's active plugin groups have to arrive as real Definitions,
    // and a Config that emitted the map but not the imports (or the other
    // way round) leaves an SDK that refuses every plugin kind at runtime
    // while every builtin-only test stays green.
    test('the model\'s plugin definitions reach the feature', (t) {
      final defs = FEATURE_PLUGINS['secrets'];

      if (null == defs || defs.isEmpty) {
        // This project selects no plugin group. Nothing to check.
        t.skip('no plugin group active in this model');
        return;
      }

      for (final one in defs) {
        ok(one is Map && one['name'] is String,
            'FEATURE_PLUGINS carries something that is not a voxgig/plugin '
            'Definition: $one');
      }
    });


    // --- auth suppression -------------------------------------------------

    test('auth null suppresses the credential, chain or no chain', (t) async {
      final wire = Wire();
      final sdk = UnivecSDK(<String, dynamic>{
        'base': RAWBASE,
        'auth': null,
        'allow': <String, dynamic>{'op': 'direct,graphql'},
        'system': <String, dynamic>{'fetch': wire.fetch},
        'feature': <String, dynamic>{
          'secrets': <String, dynamic>{
            'active': true,
            'providers': [GoodProvider('CHAINKEY01')],
          }
        },
      });

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(1, wire.sent);
      equal(null, wire.calls[0]['auth'],
          'a credential went out despite auth: null');

      // The suppression survives option validation rather than being
      // replaced by the optspec's default auth map.
      equal(null, sdk.options()['auth']);

      // And the chain DID resolve - the suppression is at the header, not a
      // side effect of an empty chain.
      equal('CHAINKEY01', secretsOf(sdk).credential);
    });


    test('auth null suppresses an EXPLICIT apikey too', (t) async {
      final wire = Wire();
      final sdk = UnivecSDK(<String, dynamic>{
        'base': RAWBASE,
        'apikey': 'OPTKEY01',
        'auth': null,
        'allow': <String, dynamic>{'op': 'direct,graphql'},
        'system': <String, dynamic>{'fetch': wire.fetch},
        'feature': <String, dynamic>{
          'secrets': <String, dynamic>{
            'active': true,
            'providers': <dynamic>[],
          }
        },
      });

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(1, wire.sent);
      equal(null, wire.calls[0]['auth']);
    });


    // --- FAIL CLOSED: the raw paths ---------------------------------------
    //
    // direct() and graphql() run NO feature hooks at all. If resolution
    // lived only in a PreSpec hook these would send an unauthenticated
    // request and never notice. They are covered because the feature
    // resolves at the transport, which is the one seam both cross.

    test('a provider ERROR fails direct() rather than sending', (t) async {
      // THE RULE, asserted first so a regression reports the leak itself.
      final wire = Wire();
      final broken = BrokenProvider();
      final res =
          await rawSdk(wire, [broken]).direct(<String, dynamic>{'path': '/thing'});

      equal(0, wire.sent,
          'a request must not go out unauthenticated because a provider '
          'broke, but one reached the transport: ${wire.leak()}');
      equal(false, res['ok'], 'expected a failure, got: $res');
      ok('${res['err']}'.contains('vault unreachable'),
          'the failure must carry the provider\'s own message, got: '
          '${res['err']}');
      equal(1, broken.asked, 'the chain was never asked at all');

      // CONTROL, which makes that zero mean REFUSED rather than UNWIRED:
      // the same construction with a WORKING provider must reach the same
      // transport, once, carrying the credential.
      final control = Wire();
      final ok2 = await rawSdk(control, [GoodProvider()])
          .direct(<String, dynamic>{'path': '/thing'});

      equal(true, ok2['ok'], 'the control request failed: $ok2');
      equal(1, control.sent,
          'the control request never reached system.fetch, so this test '
          'cannot observe a request going out at all');
      credentialIs(control.calls[0]['auth'], 'RAWKEY01');
    });


    test('a provider ERROR fails graphql() rather than sending', (t) async {
      final wire = Wire();
      final res =
          await rawSdk(wire, [BrokenProvider()]).graphql('{ thing }', {});

      equal(0, wire.sent,
          'a graphql request must not go out unauthenticated, but one '
          'reached the transport: ${wire.leak()}');
      equal(false, res['ok'], 'expected a failure, got: $res');
      ok('${res['err']}'.contains('vault unreachable'),
          'the failure must carry the provider\'s own message, got: '
          '${res['err']}');

      final control = Wire();
      final ok2 =
          await rawSdk(control, [GoodProvider()]).graphql('{ thing }', {});

      equal(true, ok2['ok'], 'the control request failed: $ok2');
      equal(1, control.sent,
          'the control request never reached system.fetch, so this test '
          'cannot observe a request going out at all');
      credentialIs(control.calls[0]['auth'], 'RAWKEY01');
    });


    test('a BROKEN store does not fall through to a weaker one', (t) async {
      // sekreto's miss-vs-error invariant at its sharpest: a store sitting
      // BEHIND the broken one holds a usable value, and reaching it would
      // look like success while silently downgrading the credential.
      final wire = Wire();
      final res = await rawSdk(wire, [
        BrokenProvider(),
        <String, dynamic>{
          'kind': 'memory',
          'values': <String, String>{'APIKEY': 'WEAKER01'},
        }
      ]).direct(<String, dynamic>{'path': '/thing'});

      equal(0, wire.sent,
          'the chain fell through a broken store to a weaker one: '
          '${wire.leak()}');
      equal(false, res['ok']);
      ok('${res['err']}'.contains('vault unreachable'),
          'expected the provider error, got: ${res['err']}');
    });


    // --- FAIL CLOSED: the entity path -------------------------------------
    //
    // The hook pipeline, through the offline harness. Its `server` is
    // installed as utility.fetcher BEFORE features initialise, so
    // SecretsFeature wraps it and the server IS the inner transport - the
    // same counter argument as the raw legs above.

    test('a provider ERROR fails an entity op rather than sending', (t) async {
      final broken = BrokenProvider();
      final ent = entitySdk([broken]);

      final res = await ent.harness.op(<String, dynamic>{'op': 'load'});

      equal(0, ent.sent,
          'an entity op must not go out unauthenticated because a provider '
          'broke, but one reached the transport: ${ent.leak()}');
      equal(false, res['ok'], 'expected the op to fail, got: $res');
      ok('${res['error']}'.contains('vault unreachable'),
          'the failure must carry the provider\'s own message, got: '
          '${res['error']}');
      equal(1, broken.asked, 'the chain was never asked at all');

      // CONTROL: the same pipeline with a WORKING provider reaches the same
      // transport exactly once, carrying the credential.
      final control = entitySdk([GoodProvider()]);
      final ok2 = await control.harness.op(<String, dynamic>{'op': 'load'});

      equal(true, ok2['ok'], 'the control op failed: ${ok2['error']}');
      equal(1, control.sent,
          'the control op never reached the transport, so this test cannot '
          'observe a request going out at all');
      credentialIs(control.auth(0), 'RAWKEY01');
    });


    test('auth null suppresses the credential on the entity path too',
        (t) async {
      final ent = entitySdk([GoodProvider()], <String, dynamic>{'auth': null});

      final res = await ent.harness.op(<String, dynamic>{'op': 'load'});

      equal(true, res['ok']);
      equal(1, ent.sent);
      equal(null, ent.auth(0),
          'a credential went out on the entity path despite auth: null');
    });


    // --- resolution lifecycle ---------------------------------------------

    test('a provider recovers after a transient failure', (t) async {
      // A settled FAILURE must not be held forever: keeping it meant a
      // transient vault outage poisoned the client permanently, every later
      // operation failing with the original error long after the vault
      // recovered.
      final wire = Wire();
      final sdk = rawSdk(wire, [FlakyProvider()]);

      final first = await sdk.direct(<String, dynamic>{'path': '/one'});
      equal(false, first['ok'], 'the first attempt should surface the outage');
      equal(0, wire.sent);

      final second = await sdk.direct(<String, dynamic>{'path': '/two'});
      equal(true, second['ok'], 'the second attempt should recover: $second');
      equal(1, wire.sent);
      credentialIs(wire.calls[0]['auth'], 'RECOVERED01');
    });


    test('cache true asks the chain once', (t) async {
      final wire = Wire();
      final counting = CountingProvider();
      final sdk = rawSdk(wire, [counting]);

      await sdk.direct(<String, dynamic>{'path': '/one'});
      await sdk.direct(<String, dynamic>{'path': '/two'});

      equal(1, counting.asked, 'a cached resolution asked the chain twice');
      credentialIs(wire.calls[1]['auth'], 'KEY1');
    });


    // A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this
    // feature used to override from the layer above.
    //
    // DEFAULT caching here, which is the whole point: `cache: true` is
    // about holding a HIT (the test above pins that half), and keeping the
    // settled future after a miss meant the chain was never asked again for
    // the life of the client. A secret provisioned after startup (a mounted
    // file, a vault policy granted a minute late) was invisible forever,
    // and the only workaround was giving up hit caching entirely.
    test('cache true re-asks after a MISS, so a late secret is picked up',
        (t) async {
      final wire = Wire();
      final late = LateProvider();
      final sdk = rawSdk(wire, [late]);

      await sdk.direct(<String, dynamic>{'path': '/one'});
      equal(null, wire.calls[0]['auth'],
          'the chain has nothing yet, so no credential should go out');

      final asked = late.asked;
      ok(0 < asked, 'the chain was never asked');

      // The secret is provisioned while the client is live.
      late.present = true;

      await sdk.direct(<String, dynamic>{'path': '/two'});

      ok(asked < late.asked,
          'the MISS was cached: a secret that appears later can never be '
          'picked up');
      credentialIs(wire.calls[1]['auth'], 'LATEKEY01');
    });


    test('cache false asks the chain on every request', (t) async {
      // `cache: false` is documented as "every resolve asks the chain
      // again". Caching the settled future made that a lie.
      final wire = Wire();
      final counting = CountingProvider();
      final sdk = rawSdk(wire, [counting], <String, dynamic>{'cache': false});

      await sdk.direct(<String, dynamic>{'path': '/one'});
      await sdk.direct(<String, dynamic>{'path': '/two'});

      ok(1 < counting.asked,
          'the chain was asked once and cached, despite cache: false');
      credentialIs(wire.calls[1]['auth'], 'KEY2');
    });


    test('an UNCACHED miss after a hit retracts the credential', (t) async {
      // A revocation must stop going out on the wire.
      final store = RetractingProvider();
      final wire = Wire();
      final sdk = rawSdk(wire, [store], <String, dynamic>{'cache': false});

      await sdk.direct(<String, dynamic>{'path': '/one'});
      credentialIs(wire.calls[0]['auth'], 'LIVEKEY01');

      store.revoked = true;
      await sdk.direct(<String, dynamic>{'path': '/two'});

      equal(2, wire.sent);
      equal(null, wire.calls[1]['auth'],
          'a revoked credential kept going out on the wire');
    });

  });


  // ACCESS-TOKEN EXCHANGE.
  //
  // What the chain resolves is a REFRESH token, which is POSTed to a token
  // endpoint for a short-lived ACCESS token; the access token is what the
  // Authorization header carries; and when the API answers 401 the client
  // buys another and tries the same request again, once.
  describe('secrets exchange', () {

    UnivecSDK exchangeSdk(Wire wire, [Map<String, dynamic>? extra]) {
      final secrets = <String, dynamic>{
        'active': true,
        'name': 'refresh_token',
        'providers': [
          <String, dynamic>{
            'kind': 'memory',
            'values': <String, String>{'REFRESH_TOKEN': REFRESH},
          }
        ],
        'exchange': <String, dynamic>{'active': true},
      };
      if (null != extra) {
        extra.forEach((k, v) => secrets[k] = v);
      }

      return UnivecSDK(<String, dynamic>{
        'base': EXBASE,
        'allow': <String, dynamic>{'op': 'direct,graphql'},
        'system': <String, dynamic>{'fetch': wire.fetch},
        'feature': <String, dynamic>{'secrets': secrets},
      });
    }


    test('the refresh token buys an access token the request carries',
        (t) async {
      final wire = Wire();
      final sdk = exchangeSdk(wire);

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(1, wire.token().length, 'expected exactly one token purchase');
      // MARSHALLED, not concatenated: a refresh token carrying a quote or a
      // newline must arrive as that literal value.
      equal('{"refresh_token":"$REFRESH"}', wire.token()[0]['body']);

      equal(1, wire.api().length);
      credentialIs(wire.api()[0]['auth'], 'ACCESS01');
    });


    test('one purchase serves many requests', (t) async {
      final wire = Wire();
      final sdk = exchangeSdk(wire);

      await sdk.direct(<String, dynamic>{'path': '/one'});
      await sdk.direct(<String, dynamic>{'path': '/two'});
      await sdk.direct(<String, dynamic>{'path': '/three'});

      equal(1, wire.token().length,
          'a token still working must not be re-bought');
      equal(3, wire.api().length);
    });


    test('concurrent first requests share ONE purchase', (t) async {
      final wire = Wire();
      final sdk = exchangeSdk(wire);

      await Future.wait(<Future<dynamic>>[
        sdk.direct(<String, dynamic>{'path': '/a'}),
        sdk.direct(<String, dynamic>{'path': '/b'}),
        sdk.direct(<String, dynamic>{'path': '/c'}),
      ]);

      equal(1, wire.token().length,
          'three operations at once must not open three token requests');
    });


    test('a 401 buys another token and retries the SAME request', (t) async {
      final wire = Wire(apiStatus: [401, 200]);
      final sdk = exchangeSdk(wire);

      final res = await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(2, wire.token().length, 'expected a second token purchase');
      equal(2, wire.api().length, 'expected the request to be retried');
      credentialIs(wire.api()[0]['auth'], 'ACCESS01');
      // The retry must carry the NEW token, not the spent one.
      credentialIs(wire.api()[1]['auth'], 'ACCESS02');
      equal(true, res['ok'], 'the caller sees the successful retry');
    });


    test('the retry happens once, not in a loop', (t) async {
      // Every API call is refused: a second 401 on a token bought moments
      // ago is a real failure, and spinning on it would hang.
      final wire = Wire(apiStatus: [401]);
      final sdk = exchangeSdk(wire);

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(2, wire.api().length, 'exactly one retry');
      equal(2, wire.token().length);
    });


    test('a status outside exchange.statuses is not an expiry', (t) async {
      final wire = Wire(apiStatus: [403]);
      final sdk = exchangeSdk(wire);

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(1, wire.api().length, '403 is not in the default statuses');
      equal(1, wire.token().length);
    });


    test('exchange.statuses is configurable', (t) async {
      final wire = Wire(apiStatus: [403, 200]);
      final sdk = exchangeSdk(wire, <String, dynamic>{
        'exchange': <String, dynamic>{
          'active': true,
          'statuses': [403],
        }
      });

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(2, wire.api().length, '403 was declared an expiry');
    });


    test('the endpoint and field names are configurable', (t) async {
      final wire =
          Wire(tokenPath: 'oauth/grant', responseField: 'token');
      final sdk = exchangeSdk(wire, <String, dynamic>{
        'exchange': <String, dynamic>{
          'active': true,
          'path': 'oauth/grant',
          'request': 'grant',
          'response': 'token',
        }
      });

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(1, wire.token().length);
      ok('${wire.token()[0]['url']}'.endsWith('/oauth/grant'),
          'the token endpoint is relative to base: ${wire.token()[0]['url']}');
      equal('{"grant":"$REFRESH"}', wire.token()[0]['body']);
      credentialIs(wire.api()[0]['auth'], 'ACCESS01');
    });


    test('an explicit exchange.refresh wins over the chain', (t) async {
      final wire = Wire();
      final sdk = exchangeSdk(wire, <String, dynamic>{
        'exchange': <String, dynamic>{'active': true, 'refresh': 'EXPLICIT01'}
      });

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal('{"refresh_token":"EXPLICIT01"}', wire.token()[0]['body']);
    });


    test('an explicit apikey is spent before anything is bought', (t) async {
      // A caller who already holds an access token should use it; expiry is
      // what moves them onto the exchange, and the API says when.
      final wire = Wire();
      final sdk = UnivecSDK(<String, dynamic>{
        'base': EXBASE,
        'apikey': 'HELDTOKEN01',
        'allow': <String, dynamic>{'op': 'direct,graphql'},
        'system': <String, dynamic>{'fetch': wire.fetch},
        'feature': <String, dynamic>{
          'secrets': <String, dynamic>{
            'active': true,
            'name': 'refresh_token',
            'providers': [
              <String, dynamic>{
                'kind': 'memory',
                'values': <String, String>{'REFRESH_TOKEN': REFRESH},
              }
            ],
            'exchange': <String, dynamic>{'active': true},
          }
        },
      });

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(0, wire.token().length, 'nothing needed buying');
      credentialIs(wire.api()[0]['auth'], 'HELDTOKEN01');
    });


    test('no refresh token anywhere is an error, not an unauthenticated call',
        (t) async {
      final wire = Wire();
      final sdk = UnivecSDK(<String, dynamic>{
        'base': EXBASE,
        'allow': <String, dynamic>{'op': 'direct,graphql'},
        'system': <String, dynamic>{'fetch': wire.fetch},
        'feature': <String, dynamic>{
          'secrets': <String, dynamic>{
            'active': true,
            'name': 'refresh_token',
            'providers': [EmptyProvider()],
            'exchange': <String, dynamic>{'active': true},
          }
        },
      });

      final res = await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(false, res['ok'], 'expected a failure, got: $res');
      equal(0, wire.api().length,
          'a request must not go out unauthenticated because the chain was '
          'empty: ${wire.leak()}');
      ok('${res['err']}'.contains('no refresh token'),
          'expected the missing-refresh-token error, got: ${res['err']}');
    });


    test('a failing token endpoint fails the request rather than sending',
        (t) async {
      final wire = Wire(apiStatus: [401], tokenFails: true);
      final sdk = exchangeSdk(wire);

      final res = await sdk.direct(<String, dynamic>{'path': '/thing'});

      ok(null != res, 'the caller got an answer rather than a hang');
      equal(0, wire.api().length,
          'nothing may go out when the first purchase failed');
    });


    test('auth null suppresses the credential, refusal or not', (t) async {
      // A refusal of a deliberately unauthenticated request is not an
      // expired token: buying one and retrying would transmit exactly the
      // credential the caller suppressed.
      final wire = Wire(apiStatus: [401]);
      final sdk = UnivecSDK(<String, dynamic>{
        'base': EXBASE,
        'auth': null,
        'allow': <String, dynamic>{'op': 'direct,graphql'},
        'system': <String, dynamic>{'fetch': wire.fetch},
        'feature': <String, dynamic>{
          'secrets': <String, dynamic>{
            'active': true,
            'name': 'refresh_token',
            'providers': [
              <String, dynamic>{
                'kind': 'memory',
                'values': <String, String>{'REFRESH_TOKEN': REFRESH},
              }
            ],
            'exchange': <String, dynamic>{'active': true},
          }
        },
      });

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(1, wire.api().length, 'a suppressed request must not be retried');
      equal(null, wire.api()[0]['auth'],
          'no credential may be sent when auth is suppressed');

      // AND NO PURCHASE. resolve() runs before _withRefresh's suppression
      // check, so the refresh token used to go to the token endpoint in a
      // request body even here. Stopping the retry does not unsend it, and
      // only the token endpoint can see this.
      equal(0, wire.token().length,
          'auth null suppressed the credential but the refresh token was '
          'still POSTed to the exchange endpoint');
    });


    test('test mode buys nothing and needs no token endpoint', (t) async {
      final wire = Wire();
      final sdk = UnivecSDK.test(<String, dynamic>{}, <String, dynamic>{
        'base': EXBASE,
        'allow': <String, dynamic>{'op': 'direct,graphql'},
        'system': <String, dynamic>{'fetch': wire.fetch},
        'feature': <String, dynamic>{
          'secrets': <String, dynamic>{
            'active': true,
            'name': 'refresh_token',
            'providers': [
              <String, dynamic>{
                'kind': 'memory',
                'values': <String, String>{'REFRESH_TOKEN': REFRESH},
              }
            ],
            'exchange': <String, dynamic>{'active': true},
          }
        },
      });

      await sdk.direct(<String, dynamic>{'path': '/thing'});

      equal(0, wire.sent, 'test mode must not do IO');
      // A deterministic placeholder, so offline suites need no
      // configuration.
      equal('test-access_token', secretsOf(sdk).credential);
    });

  });
}


// A store whose secret is REVOKED partway through the run.
// Absent until `present` is set, then answers: a secret provisioned while
// the client is already live.
class LateProvider extends Provider {
  bool present = false;
  int asked = 0;

  @override
  FutureOr<String?> lookup(String _name) {
    asked++;
    return present ? 'LATEKEY01' : null;
  }

  @override
  String describe() => 'late:test';
}

class RetractingProvider extends Provider {
  bool revoked = false;

  @override
  FutureOr<String?> lookup(String _name) => revoked ? null : 'LIVEKEY01';

  @override
  String describe() => 'retracting:test';
}
