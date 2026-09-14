// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:convert';

import '../base/BaseFeature.dart';

// The plugin DEFINITIONS the model selected for this feature, emitted by
// Config generically from the catalogue's active `plugin.def` entries.
// Upstream sekreto's contract since the registry was retired: a kind not
// passed in `plugins` is unknown to that Sekreto, so the model's choice of
// plugin groups IS the SDK's provider vocabulary.
//
// Config.dart imports this file (the generated #ImportFeatures block) and
// this file imports Config.dart back, which is a CYCLE - legal in Dart, and
// safe here because `FEATURE_PLUGINS` is a lazily-initialised top-level
// final that is first read in `init`, long after both libraries have
// loaded. Config emits the map unconditionally (empty when no group is
// active), so this import resolves in an SDK that carries the feature
// source without selecting a single plugin group.
import '../../Config.dart' show FEATURE_PLUGINS;

import 'sekreto/src/provider.dart';
import 'sekreto/src/sekreto.dart';
import 'sekreto/src/spec.dart';
import 'sekreto/src/support.dart';


// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it. The dart port of
// tm/ts/src/feature/secrets/SecretsFeature.ts - same contract, dart idiom,
// and structurally the GO port rather than the ts one (see below).
//
// The SDK's `apikey` option keeps exactly its old meaning: an explicit
// credential given in code. This feature makes it ONE SOURCE among several
// rather than the only one: when active, the apikey is resolved through a
// sekreto chain in which the explicit option (when set) is the FIRST
// provider - a `memory` store named `options` - so an explicit value always
// wins, by sekreto's own first-hit rule rather than by special-case logic.
// When the option is unset, the remaining providers (env, dotenv, a vault)
// are asked in order, and moving a credential from code to a vault becomes
// a configuration change.
//
// WHY THE TRANSPORT SEAM, AND NOT PreSpec. Dart's feature hooks ARE
// awaited (EntityBase's `fres = featureHook(ctx, 'PreSpec'); if (fres is
// Future) await fres;`), so a PreSpec resolve COULD fail an entity op the
// ts way. It would not be enough. `UnivecSDK.prepare()` runs no
// feature hooks at all, and `direct()` and `graphql()` reach the wire
// through it - so a feature that only resolved in PreSpec would leave both
// RAW paths uncredentialed and, worse, fail OPEN: a broken vault would
// still send the request, unauthenticated. Every wire path instead crosses
// one mutable field, `ctx.utility.fetcher`, so this feature wraps that -
// the same seam the netsim/retry/cache features wrap - and resolves there.
// One gate, every path, entity and raw alike.
//
// THE CREDENTIAL LIVES IN FEATURE STATE, never in the shared options map.
// The ts reference writes `client._options.apikey` so the synchronous
// prepareAuth picks it up; here the transport wrapper rewrites the header
// itself, from the same `options.auth.prefix` prepareAuth uses, so the two
// cannot drift and the options map stays exactly as makeOptions built it.
// (go documents the same choice for a stronger reason - a shared map read
// by concurrent goroutines. Dart is single-isolate, so this is not a data
// race here; it is what makes the raw paths work and keeps the seam the
// single writer of the credential.)
//
// MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
// op proceeds, unauthenticated if nothing else supplies a credential. A
// provider ERROR (unreachable vault, bad creds) must FAIL the op: a broken
// vault never degrades into an unauthenticated request. The wrapper
// refuses to call the inner transport at all in that case, and answers
// with the provider's OWN message.
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What
// the chain resolves is then a REFRESH token, which buys a short-lived
// ACCESS token from a token endpoint (`exchange.path`, relative to
// options.base); the access token is what every request carries, and when
// a response status in `exchange.statuses` (401) says it is spent the
// wrapper buys another and retries the same request once. Concurrent
// purchases share the one in-flight exchange; test mode buys nothing and
// answers with a deterministic fake token.
class SecretsFeature extends BaseFeature {
  dynamic _client;

  // The LIVE options map (root ctx options), read for `auth`, `apikey`,
  // `base` and `system.fetch`. NEVER written: see the note above.
  dynamic _liveopts;

  Sekreto? _sekreto;
  String _secretname = 'apikey';
  bool _cache = true;

  // A chain that would not BUILD (an unknown provider kind, a spec a
  // definition refused). init cannot fail construction the way ts's
  // throwing init does, so the failure is held here and the transport gate
  // refuses to send - a misconfigured chain is fail-closed, not silently
  // unauthenticated.
  Object? _initerr;

  // The RESOLVED credential, held in feature state and injected into each
  // request at the transport seam.
  String _cred = '';

  // The one in-flight resolution concurrent operations share. Dart is
  // single-isolate, so a plain nullable Future is all go's mutex and
  // channel machinery collapses to.
  Future<void>? _resolving;

  // Exchange state: null config when off; the refresh credential the chain
  // resolved; the single in-flight purchase.
  _Exchange? _exchange;
  String _refresh = '';
  Future<String>? _buying;

  SecretsFeature() {
    version = '0.1.0';
    name = 'secrets';
    active = true;
  }

  // Sync by feature contract (init cannot await): build the chain only,
  // never look anything up here.
  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    _liveopts = ctx.options;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];

    if (!active) {
      return null;
    }

    final rawname = options['name'];
    _secretname =
        (rawname is String && rawname.isNotEmpty) ? rawname : 'apikey';
    _cache = false != options['cache'];

    // Exchange config, normalised once. Null when off, so every later
    // decision is a null check rather than a repeated `true == ...active`.
    final xopts = options['exchange'];
    if (xopts is Map && true == xopts['active']) {
      _exchange = _Exchange(
        path: _str(xopts['path'], 'auth/token'),
        method: _str(xopts['method'], 'POST'),
        request: _str(xopts['request'], 'refresh_token'),
        response: _str(xopts['response'], 'access_token'),
        statuses: _ints(xopts['statuses'], const [401]),
        retries: xopts['retries'] is num ? (xopts['retries'] as num).toInt() : 1,
      );
    }

    // The explicit credential, when set, is the first store in the chain.
    //
    // WHICH option that is depends on the exchange. Without one, the secret
    // being resolved IS the credential the transport sends, so `apikey` is
    // it. With one, the secret is a REFRESH token and `apikey` means the
    // opposite thing - an access token the caller already holds - so the
    // explicit seat belongs to `exchange.refresh`, and apikey is left alone
    // to serve as the starting access token (see _resolveonce).
    final explicit = null == _exchange
        ? _optstr('apikey')
        : (xopts is Map ? _str(xopts['refresh'], '') : '');

    final providers = <Object?>[];

    if (explicit.isNotEmpty) {
      // `envkey` VALIDATES the name, and a bad one (`Api.Token`, `api..token`)
      // raises. Held rather than thrown: init runs inside the SDK
      // constructor, where a throw is a stack trace from `UnivecSDK(...)`
      // naming nothing the caller can act on. The transport gate reports it
      // instead - with sekreto's own message - and refuses to send, which is
      // the same fail-closed answer a broken store gets.
      try {
        providers.add(ProviderSpec(
          kind: 'memory',
          name: 'options',
          values: <String, String>{envkey(_secretname): explicit},
        ));
      } catch (err) {
        _initerr = err;
      }
    }

    final given = options['providers'];
    if (given is List) {
      for (final p in given) {
        // A live Provider or a built ProviderSpec joins the chain as it is.
        // A declarative MAP - `{ kind: 'env', prefix: 'X' }`, the shape a
        // config file and the docs use - goes through sekreto's own
        // converter, because the Sekreto constructor accepts nothing else
        // ("sekreto: not a provider or a provider spec").
        if (p is ProviderSpec || p is Provider) {
          providers.add(p);
        } else if (p is Map) {
          try {
            providers.add(specof(Map<String, dynamic>.from(
                p.map((k, v) => MapEntry('$k', v)))));
          } catch (err) {
            _initerr = err;
          }
        } else {
          _initerr = SekretoError(
              'secrets: not a provider or a provider spec: ${p ?? ''}');
        }
      }
    }

    try {
      _sekreto = Sekreto(
        providers: providers,
        plugins: FEATURE_PLUGINS[name] ?? const <Object?>[],
        cache: _cache,
      );
    } catch (err) {
      _initerr = err;
    }

    // NO `client._secrets = this` HERE, and the omission is load-bearing.
    // The ts and js ports plant that field for their `secrets()` accessor
    // to read; in Dart a leading underscore is LIBRARY-private, and this
    // file is a different library from UnivecSDK.dart - so a dynamic
    // `_client._secrets = this` would create/seek a distinct private symbol
    // and throw NoSuchMethodError at construction. The generated accessor
    // finds this feature by name in `client.features` instead, which is
    // public and needs no seam at all.

    // Wrap the transport. Unlike the ts reference - which wraps only when
    // exchanging, because its PreSpec hook covers the ordinary case - the
    // wrapper is the fail-closed gate AND the credential injector here, so
    // it is installed whenever the feature is active.
    final self = this;
    final utility = ctx.utility;
    final inner = utility.fetcher;

    utility.fetcher = (dynamic ctx2, dynamic url, dynamic fetchdef) async {
      return self._transport(ctx2, url, fetchdef, inner);
    };

    return null;
  }

  // The LIVE Sekreto instance, for the SDK's secrets() accessor and for
  // callers who want arbitrary secrets or redaction:
  //
  //   await sdk.secrets().get('db.password')
  //   sdk.secrets().redact(logline)
  //
  // Never a clone: sekreto holds provider state (caches, vault leases) that
  // has to stay live to be worth anything.
  Sekreto? sekreto() => _sekreto;

  // The resolved credential (empty when none) - the state the transport
  // injects. The dart peer of go's Credential(): tests and callers read it
  // here rather than from the options map, which this feature never writes.
  String get credential => _cred;

  // Resolve the secret. Concurrent operations share the one IN-FLIGHT
  // future; a settled HIT is kept only when caching is on (`cache: false`
  // means every resolve asks the chain again). A FAILURE is always cleared,
  // so a transient vault outage never poisons the client permanently - the
  // next operation asks the chain again.
  //
  // A MISS is cleared too, however caching is set. That rule is sekreto's,
  // not this feature's: `A miss is never cached: the next read asks again`,
  // in sekreto's own source (sekreto/src/sekreto.dart). Keeping a settled
  // miss here would override that from the layer above, and a secret
  // provisioned after startup - a mounted file, a policy granted a minute
  // late - would never be picked up for the life of the client. `cache` is
  // about caching a HIT; it was never a promise to keep saying no.
  Future<void> resolve() {
    final err = _initerr;
    if (null != err) {
      return Future<void>.error(err);
    }

    final current = _resolving;
    if (null != current) {
      return current;
    }

    final inflight = _resolveonce().then((bool hit) {
      if (!_cache || !hit) {
        _resolving = null;
      }
    }, onError: (Object e) {
      _resolving = null;
      throw e;
    });

    _resolving = inflight;

    return inflight;
  }

  // Resolve once, reporting whether a credential came out of it. That bool
  // is the whole of what resolve() needs to tell a cacheable HIT from a miss
  // it must not keep.
  Future<bool> _resolveonce() async {
    final sek = _sekreto;
    if (null == sek) {
      return false;
    }

    // `tryget` is FutureOr: a chain of purely local stores answers without
    // yielding. `await` reads either, and this function being async is what
    // turns a SYNCHRONOUS provider throw into a failed future rather than
    // an exception escaping resolve()'s caller.
    final found = await sek.tryget(_secretname);

    if (null == _exchange) {
      // An UNCACHED miss after an earlier hit is a revocation: the chain
      // now says no provider has the secret, so the resolved value must not
      // keep going out on the wire. (An explicit apikey OPTION is never
      // lost here - it seats FIRST in the chain as a memory provider, so
      // the chain HITS while one is set and this branch writes it back.)
      _cred = found ?? '';
      return null != found;
    }

    // Exchanging: what the chain resolved is the REFRESH token, kept for
    // every later purchase. A miss is not fatal here - an explicit `apikey`
    // may already hold a usable access token, and the API is what gets to
    // say whether it does.
    _refresh = found ?? '';

    if (_cred.isEmpty) {
      // A starting access token supplied as the OPTION.
      _cred = _optstr('apikey');
    }

    if (_cred.isNotEmpty) {
      // Spend it: if it is stale the API answers with an expiry status and
      // the transport wrapper buys another, which is the same path expiry
      // takes anyway.
      return true;
    }

    // `auth: null` is the documented way to send NO credential, and a
    // purchase is a credential-bearing call: the refresh token goes to the
    // token endpoint in the request body. _withRefresh honours suppression
    // for the RETRY, but it runs after this - by then the refresh token has
    // already left the process, and no later check can call it back. The
    // suppression has to be honoured here, before the first purchase, or it
    // only ever half-held.
    if (null == _rawauth()) {
      return false;
    }

    _cred = await _buy();

    return true;
  }

  // The transport wrapper: the ONE seam every wire path crosses.
  //
  // Entity ops, prepare()/direct()/graphql() and the exchange retries all
  // come through here, so resolving HERE is what gives the raw paths -
  // which run no feature hooks at all - the same credential the entity
  // pipeline gets. resolve() is shared and cached: concurrent callers join
  // the in-flight attempt, a cached success is free, and with `cache:
  // false` the chain is asked once per REQUEST, which is that option's
  // meaning.
  Future<dynamic> _transport(
      dynamic ctx, dynamic url, dynamic fetchdef, dynamic inner) async {
    // FAIL CLOSED. A provider ERROR refuses the request, carrying the
    // provider's own message - never an unauthenticated send. Returned as
    // an error VALUE rather than thrown, which is this pipeline's shape for
    // a transport failure (netsim does the same): _rawRequest reports it as
    // `{ok: false, err: ...}` and an entity op fails on it.
    try {
      await resolve();
    } catch (err) {
      return ctx.error('secrets_provider', _why(err));
    }

    // Inject the resolved credential into THIS request's header. The header
    // was built by prepareAuth from the options apikey; the chain-resolved
    // value lives in feature state instead, so the wrapper writes it here -
    // same construction, same suppression rules.
    if (_cred.isNotEmpty) {
      _reauth(fetchdef, _cred);
    }

    if (null == _exchange) {
      return Future.value(inner(ctx, url, fetchdef));
    }

    return _withRefresh(ctx, url, fetchdef, inner);
  }

  // Buy a token and try the request again when the API says the current one
  // is spent.
  //
  // The retry rewrites the authorization header IN PLACE on the fetchdef,
  // because the header was built by the synchronous prepareAuth before this
  // request left, and it carries the token that just failed. Rebuilt the
  // way prepareAuth builds it, from the same options auth.prefix, so the
  // two cannot drift.
  Future<dynamic> _withRefresh(
      dynamic ctx, dynamic url, dynamic fetchdef, dynamic inner) async {
    // `auth: null` is the documented way to send NO credential, and
    // prepareAuth honours it by removing the header. A refusal of a
    // deliberately unauthenticated request is not an expired token and
    // cannot be fixed by buying one - retrying would transmit exactly the
    // credential the caller suppressed.
    if (null == _rawauth()) {
      return Future.value(inner(ctx, url, fetchdef));
    }

    final max = _exchange!.retries;
    var attempt = 0;

    for (;;) {
      // The credential THIS attempt goes out with, captured before it
      // leaves: it is what tells a stale refusal apart from a fresh one.
      final used = _cred;

      final res = await Future.value(inner(ctx, url, fetchdef));

      if (attempt >= max || !_spent(res)) {
        return res;
      }

      // Another request may have bought a token while this one was in
      // flight. Concurrent expiries share the in-flight purchase, but
      // STAGGERED ones do not - so spend what is current before buying: a
      // second exchange for a token that is already fresh is wasted, and on
      // a provider that invalidates the previous credential on issuance it
      // breaks the first request's own retry.
      final current = _cred;
      String token;

      if (current.isNotEmpty && current != used) {
        token = current;
      } else {
        try {
          token = await _buy();
        } catch (_err) {
          // The purchase failed: answer with the API's own refusal rather
          // than this one. The caller asked for data, and the refusal is
          // the more useful of the two - the exchange error is a symptom.
          return res;
        }
        _cred = token;
      }

      _reauth(fetchdef, token);

      attempt++;
    }
  }

  bool _spent(dynamic res) {
    if (null == res || res is Error || res is Exception || res is! Map) {
      return false;
    }
    final status = res['status'];
    if (status is! num) {
      return false;
    }
    return _exchange!.statuses.contains(status.toInt());
  }

  // Buy an access token with the refresh token. Concurrent callers share
  // the ONE in-flight purchase: a client running four operations at once
  // must not open four token requests. The slot is cleared once settled, so
  // the next expiry buys a fresh token rather than replaying this result.
  Future<String> _buy() {
    // TEST MODE BUYS NOTHING. The test feature replaces the transport so no
    // request leaves the process; an exchange here would be the one HTTP
    // call it could not stop, and it would need a live token endpoint for a
    // suite whose whole point is not needing one. A deterministic,
    // obviously-fake token instead - the same answer makeOptions gives a
    // required server variable, for the same reason.
    if ('live' != _client.mode) {
      return Future.value('test-' + _exchange!.response);
    }

    final current = _buying;
    if (null != current) {
      return current;
    }

    final buying = _buyonce().then((String token) {
      _buying = null;
      return token;
    }, onError: (Object err) {
      _buying = null;
      throw err;
    });

    _buying = buying;

    return buying;
  }

  Future<String> _buyonce() async {
    final x = _exchange!;

    if (_refresh.isEmpty) {
      throw SekretoError(
          "secrets: no refresh token: the provider chain has no '"
          "$_secretname', and feature.secrets.exchange.refresh is unset");
    }

    // The token endpoint is RELATIVE to the base, which already carries
    // whatever account or tenant segment the server URL declares.
    var base = _optstr('base');
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    var path = x.path;
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    final url = '$base/$path';

    // From the LIVE options captured at init, NEVER from client.options():
    // that returns `struct.clone(_options)`, and makeOptions specially
    // preserves the function-valued system.fetch across merge/validate
    // exactly because a clone is where a function is lost. Reading the
    // clone risks a real token purchase where a test injected a transport.
    final system = _liveopts is Map ? _liveopts['system'] : null;
    final fetch = system is Map ? system['fetch'] : null;

    if (fetch is! Function) {
      throw SekretoError(
          'secrets: no fetch implementation for the token exchange');
    }

    // The body is MARSHALLED, never concatenated: a refresh token (or a
    // configured request-field name) carrying a quote, backslash or newline
    // must arrive as that literal value, not as malformed JSON.
    final body = jsonEncode(<String, String>{x.request: _refresh});

    // Deliberately NOT the SDK transport. The transport is what this
    // feature wraps, and sending the token request back through it would
    // recurse on the first expiry - and would route the exchange through
    // the test mock, which knows nothing about it.
    final res = await Future.value(fetch(url, <String, dynamic>{
      'method': x.method,
      'headers': <String, dynamic>{'content-type': 'application/json'},
      'body': body,
    }));

    final rawstatus = (res is Map) ? res['status'] : null;
    final status = rawstatus is num ? rawstatus.toInt() : 0;

    if (200 > status || 300 <= status) {
      throw SekretoError(
          'secrets: token exchange failed: $status from $url');
    }

    dynamic decoded;
    if (res is Map) {
      final jsonfn = res['json'];
      decoded = jsonfn is Function ? await Future.value(jsonfn()) : res['body'];
    }

    final token = decoded is Map ? decoded[x.response] : null;

    if (token is! String || token.isEmpty) {
      throw SekretoError("secrets: token exchange returned no '"
          "${x.response}' field from $url");
    }

    return token;
  }

  // The raw `auth` option: a Map when auth is configured, null when the
  // caller suppressed it with `auth: null`.
  dynamic _rawauth() => _liveopts is Map ? _liveopts['auth'] : null;

  void _reauth(dynamic fetchdef, String token) {
    if (fetchdef is! Map) {
      return;
    }
    final headers = fetchdef['headers'];
    if (headers is! Map) {
      return;
    }

    // Suppressed auth means NO header, the same answer prepareAuth gives.
    // Reached defensively for the exchange path - _withRefresh does not
    // retry at all when auth is null - but this is the function that writes
    // the credential, so it is where the rule has to hold.
    final auth = _rawauth();
    if (auth is! Map) {
      headers.remove('authorization');
      return;
    }

    final prefix = auth['prefix'];
    headers['authorization'] = (prefix is String && prefix.isNotEmpty)
        ? '$prefix $token'
        : token;
  }

  String _optstr(String key) {
    final value = _liveopts is Map ? _liveopts[key] : null;
    return value is String ? value : '';
  }

  static String _str(dynamic value, String dflt) =>
      (value is String && value.isNotEmpty) ? value : dflt;

  static List<int> _ints(dynamic value, List<int> dflt) {
    if (value is! List) {
      return dflt;
    }
    final out = <int>[];
    for (final one in value) {
      if (one is num) {
        out.add(one.toInt());
      }
    }
    return out.isEmpty ? dflt : out;
  }

  // What a failure has to say for itself. A SekretoError's whole contract
  // is its message (the shared spec pins every one of them byte for byte),
  // so it is passed through rather than decorated - a test that asserts on
  // the PROVIDER's own words is asserting on what the operator will read.
  static String _why(Object err) {
    if (err is SekretoError) {
      return err.message;
    }
    return '$err';
  }
}


class _Exchange {
  final String path;
  final String method;
  final String request;
  final String response;
  final List<int> statuses;
  final int retries;

  _Exchange({
    required this.path,
    required this.method,
    required this.request,
    required this.response,
    required this.statuses,
    required this.retries,
  });
}
