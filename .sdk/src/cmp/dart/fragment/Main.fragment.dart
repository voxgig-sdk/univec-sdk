
// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import 'Config.dart';
import 'Spec.dart';
// ProjectNameEntityBase / ProjectNameError / BaseFeature are re-exported below;
// a Dart `export` needs no matching `import`, so importing them here too is an
// unused_import. Keep only the imports actually referenced in this file.
import 'utility/ErrUtility.dart';
// PREFIXED, and deliberately not re-exported. The runtime helper class is
// named `Utility`, and so is the generated data class for an entity named
// `utility` (ProjectNameTypes.dart) — exporting both from this library makes
// the name ambiguous and NO dart SDK for such an API compiles:
//
//   Error: 'Utility' is exported from both 'lib/ProjectNameTypes.dart'
//          and 'lib/utility/Utility.dart'
//
// The entity type is the user-facing name, so it keeps the plain one; the
// runtime helper is internal plumbing and is reached through the prefix. Any
// entity name can collide with an internal class, so the prefix — not a
// rename — is what makes this safe for every API.
import 'utility/Utility.dart' as sdkutil;

export 'Config.dart' show Config, config;
export 'ProjectNameEntityBase.dart' show ProjectNameEntityBase;
export 'ProjectNameError.dart' show ProjectNameError;
export 'feature/base/BaseFeature.dart' show BaseFeature;

final sdkutil.Utility stdutil = sdkutil.Utility();

class ProjectNameSDK {
  String mode = 'live';
  dynamic _options;
  final sdkutil.Utility _utility = sdkutil.Utility();
  List<dynamic> features = [];
  dynamic rootctx;

  // Feature activity tracking store (retry attempts, cache hits, spans, ...).
  final Map<String, dynamic> track = {};

  ProjectNameSDK([dynamic options]) {
    rootctx = _utility.makeContext({
      'client': this,
      'utility': _utility,
      'config': config.toMap(),
      'options': options,
      'shared': {},
    });

    _options = _utility.makeOptions(rootctx);

    final struct = _utility.struct;

    if (true == struct.getpath(_options, 'feature.test.active')) {
      mode = 'test';
    }

    rootctx.options = _options;

    features = [];

    final featureAdd = _utility.featureAdd;
    final featureInit = _utility.featureInit;

    // Add features in the resolved order (makeOptions puts an explicit List
    // order first, else defaults to test-first). Ordering matters: the
    // `test` feature installs the base mock transport and the transport
    // features (retry/cache/netsim/proxy/ratelimit) wrap whatever is current,
    // so `test` must be added before them to sit at the base of the chain.
    final List extendList =
        _options['extend'] is List ? _options['extend'] : [];

    final featureorder =
        struct.getpath(_options, '__derived__.featureorder') ?? [];
    for (final fname in featureorder) {
      final fopts = _options['feature'][fname];
      if (fopts is Map && true == fopts['active']) {
        // An active name with no generated class is legal when an
        // extend-supplied instance carries that name (station's adopt
        // path): the instance is added below, positioned by its own
        // __after__ entry, so skip it here rather than fail construction.
        if (!config.hasFeature(fname.toString()) &&
            extendList.any((f) => fname.toString() == f.name.toString())) {
          continue;
        }
        featureAdd(rootctx, config.makeFeature(fname.toString()));
      }
    }

    for (final f in extendList) {
      featureAdd(rootctx, f);
    }

    for (final f in features) {
      featureInit(rootctx, f);
    }

    final featureHook = _utility.featureHook;
    featureHook(rootctx, 'PostConstruct');
  }

  dynamic options() {
    return _utility.struct.clone(_options);
  }

  sdkutil.Utility utility() {
    return _utility;
  }

  Future<dynamic> prepare([dynamic fetchargs]) async {
    final utility = _utility;

    final makeContext = utility.makeContext;
    final makeFetchDef = utility.makeFetchDef;
    final prepareHeaders = utility.prepareHeaders;
    final prepareAuth = utility.prepareAuth;

    fetchargs = fetchargs ?? {};

    final ctx = makeContext({
      'opname': 'prepare',
      'ctrl': fetchargs['ctrl'] ?? {},
    }, rootctx);

    final options = _options;

    // Build spec directly from SDK options + user-provided fetch args.
    final spec = Spec({
      'base': options['base'],
      'prefix': options['prefix'],
      'suffix': options['suffix'],
      'path': fetchargs['path'] ?? '',
      'method': fetchargs['method'] ?? 'GET',
      'params': fetchargs['params'] ?? {},
      'query': fetchargs['query'] ?? {},
      'body': fetchargs['body'],
      'step': 'start',
    });

    ctx.spec = spec;

    spec.headers = prepareHeaders(ctx);

    // Merge user-provided headers over SDK defaults.
    if (fetchargs['headers'] is Map) {
      (fetchargs['headers'] as Map).forEach((key, val) {
        spec.headers[key] = val;
      });
    }

    // Apply SDK auth (apikey, auth prefix, etc.)
    final authResult = prepareAuth(ctx);
    if (iserr(authResult)) {
      return authResult;
    }

    return makeFetchDef(ctx);
  }

  // Raw endpoint access is operator-controllable, like every entity op.
  // Blocking it means denying BOTH the 'direct' and 'graphql' tokens, since
  // either one reaches the same endpoint.
  Future<dynamic> direct([dynamic fetchargs]) async {
    if (!_opAllowed('direct')) {
      return _opDenied('direct');
    }

    return _rawRequest(fetchargs);
  }

  // Is this raw-access op permitted by the SDK's allow.op option?
  bool _opAllowed(String op) {
    final allow = _utility.struct.getpath(_options, 'allow.op');
    return allow is String && allow.contains(op);
  }

  dynamic _opDenied(String op) {
    final allow = _utility.struct.getpath(_options, 'allow.op');
    return {
      'ok': false,
      'err': Exception('ProjectNameSDK: $op: operation not allowed by'
          ' SDK option allow.op value: "${allow ?? ''}"'),
    };
  }

  // Ungated request path shared by direct and graphql, each of which checks
  // its own allow.op token first. Private, rather than a flag on fetchargs:
  // a caller-supplied marker would let anyone opt straight back out of the
  // gate by passing it.
  Future<dynamic> _rawRequest([dynamic fetchargs]) async {
    final utility = _utility;
    final fetcher = utility.fetcher;
    final makeContext = utility.makeContext;

    final fetchdef = await prepare(fetchargs);
    if (iserr(fetchdef)) {
      return fetchdef;
    }

    final ctx = makeContext({
      'opname': 'direct',
      'ctrl': (fetchargs ?? {})['ctrl'] ?? {},
    }, rootctx);

    try {
      final dynamic fetched =
          await Future.value(fetcher(ctx, fetchdef['url'], fetchdef));

      if (null == fetched) {
        return {
          'ok': false,
          'err': ctx.error('direct_no_response', 'response: undefined')
        };
      } else if (iserr(fetched)) {
        return {'ok': false, 'err': fetched};
      }

      final status = fetched['status'];

      // No body responses (204 No Content, 304 Not Modified) and explicit
      // zero content-length must skip JSON parsing.
      final headers = fetched['headers'];
      final contentLength =
          headers is Map ? headers['content-length'] : null;
      final noBody = 204 == status ||
          304 == status ||
          '0' == (null == contentLength ? null : contentLength.toString());

      dynamic json;
      if (!noBody) {
        try {
          final jsonFn = fetched['json'];
          json = jsonFn is Function
              ? await Future.value(jsonFn())
              : fetched['json'];
        } catch (_parseErr) {
          // Body wasn't valid JSON — surface the raw response rather than
          // throwing. data stays null; callers can inspect status/headers.
          json = null;
        }
      }

      return {
        'ok': status is num && status >= 200 && status < 300,
        'status': status,
        'headers': fetched['headers'],
        'data': json,
      };
    } catch (err) {
      return {'ok': false, 'err': err};
    }
  }

  // Raw GraphQL access: the pressure valve that makes the generated
  // surface's deliberate omissions (per-call selection sets, typed filter
  // builders, batching, subscriptions) livable — the whole schema stays
  // reachable.
  //
  // Thin wrapper over the same prepare/fetch path direct uses, with the one
  // thing raw direct cannot do for GraphQL: a GraphQL failure rides HTTP 200
  // as a top-level `errors` array, so status alone would report a failed
  // query as ok.
  //
  // NOTE: like direct, this bypasses the feature pipeline — no retry,
  // ratelimit or paging features apply.
  Future<dynamic> graphql(String query,
      [dynamic variables, dynamic ctrl]) async {
    if (!_opAllowed('graphql')) {
      return _opDenied('graphql');
    }

    final dynamic res = await _rawRequest({
      'method': 'POST',
      'headers': {'content-type': 'application/json'},
      'body': {'query': query, 'variables': variables ?? {}},
      'ctrl': ctrl ?? {},
    });

    if (res is! Map) {
      return res;
    }

    // Errors are read BEFORE any status check: a GraphQL parse or validation
    // failure comes back as HTTP 400 carrying the standard { errors: [...] }
    // body, and the raw path represents a non-2xx as ok:false with no err —
    // so returning early on status would discard the server's own
    // diagnostics, which are the only useful part of that response.
    final errors = _utility.struct.getpath(res, 'data.errors');

    if (errors is List && 0 < errors.length) {
      final first = errors[0];
      final msg = (first is Map ? first['message'] : null);
      res['ok'] = false;
      res['err'] = Exception('ProjectNameSDK: graphql: '
          '${msg is String && msg.isNotEmpty ? msg : 'graphql error'}');
      res['graphql'] = errors;
    }

    return res;
  }

  // <[SLOT]>

  static ProjectNameSDK test([dynamic testoptsarg, dynamic sdkoptsarg]) {
    final struct = stdutil.struct;
    final setpath = struct.setpath;
    final getdef = struct.getdef;
    final clone = struct.clone;
    final setprop = struct.setprop;

    final sdkopts = getdef(clone(sdkoptsarg), {});
    final testopts = getdef(clone(testoptsarg), {});
    setprop(testopts, 'active', true);
    setpath(sdkopts, 'feature.test', testopts);

    final testsdk = ProjectNameSDK(sdkopts);
    testsdk.mode = 'test';

    return testsdk;
  }

  ProjectNameSDK tester([dynamic testopts, dynamic sdkopts]) {
    return ProjectNameSDK.test(testopts, sdkopts);
  }

  Map<String, dynamic> toJSON() {
    return {'name': 'ProjectName'};
  }

  @override
  String toString() {
    return 'ProjectName ' + _utility.struct.jsonify(toJSON());
  }
}

typedef SDK = ProjectNameSDK;
