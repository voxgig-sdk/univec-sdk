import '../UnivecError.dart';

import 'voxgig_struct.dart' as vs;

import 'FetcherUtility.dart';

dynamic makeOptions(dynamic ctx) {
  final utility = ctx.utility;
  final options = ctx.options;

  // Custom utility overrides.
  final customUtils = vs.getprop(options, 'utility') ?? {};
  for (final item in vs.items(customUtils)) {
    utility.setUtility(item[0], item[1]);
  }

  final config = ctx.config ?? {};
  final cfgopts = vs.getprop(config, 'options') ?? {};

  // Standard SDK option values.
  final optspec = {
    'apikey': '',
    'base': 'http://localhost:8000',
    'secret': '',
    'prefix': '',
    'suffix': '',
    // `basic` and `secret`: HTTP Basic Auth needs a second credential and a
    // flag to say the pair is Basic rather than a single bearer token.
    'auth': {
      'prefix': '',
      'basic': false,
    },
    'headers': {
      '`\$CHILD`': '`\$STRING`',
    },
    'allow': {
      'method': 'GET,PUT,POST,PATCH,DELETE,OPTIONS',
      'op': 'create,update,load,list,remove,command,direct,graphql',
    },
    'entity': {
      '`\$CHILD`': {
        '`\$OPEN`': true,
        'active': false,
        'alias': {},
      },
    },
    'feature': {
      '`\$CHILD`': {
        '`\$OPEN`': true,
        'active': false,
      },
    },
    'utility': {},
    // Feature INSTANCES supplied at construction (the station adopt
    // path): consumed by the constructor's featureAdd loop, so they are
    // class instances, not data - `$ANY` accepts them verbatim. Without
    // this entry the seam is dead: the constructor reads
    // options.extend, but validate rejected the key.
    'extend': '`\$ANY`',
    'system': {},
    'test': {
      'active': false,
      'entity': {
        '`\$OPEN`': true,
      },
    },
    'clean': {
      'keys': 'key,token,id',
    },
    // Server-variable values for a templated base URL (OpenAPI server
    // variables): {name} placeholders in "base" are substituted from this
    // map at construction. Spec defaults arrive via the generated config;
    // user values override them. Mirrors go's make_options optspec.
    'server': {'`\$CHILD`': ''},
  };

  // Dart specific: preserve the (function-valued) system.fetch across
  // merge/validate, defaulting to the dart:io transport.
  final sysFetch = vs.getpath(options, 'system.fetch') ?? httpFetch;

  // Feature add-order. `options.feature` may be given as an ordered List of
  // { name, active, ...opts } entries (the List position IS the order in
  // which features are added), or as a { name: {opts} } map. Normalize a
  // List to a map (so merge/validate are unchanged) and remember the
  // explicit order; a map defaults to test-first so the `test` mock
  // transport is installed as the base of the transport wrapper chain.
  final featureorder = <String>[];
  dynamic mergeOptions = options ?? {};
  final rawFeature = vs.getprop(options, 'feature');
  if (rawFeature is List) {
    final fmap = <String, dynamic>{};
    for (final entry in rawFeature) {
      if (entry is Map && null != vs.getprop(entry, 'name')) {
        final fname = vs.getprop(entry, 'name').toString();
        final fopts = <String, dynamic>{};
        entry.forEach((k, v) {
          if ('name' != k) {
            fopts[k.toString()] = v;
          }
        });
        fmap[fname] = fopts;
        featureorder.add(fname);
      }
    }
    mergeOptions = vs.clone(options);
    mergeOptions['feature'] = fmap;
  }

  // `auth: null` is the documented way to disable auth outright, and
  // prepareAuth honours it before it ever reads the apikey. It cannot survive
  // validate: depending on the struct port a stored null is either REPLACED
  // by the optspec default — transmitting the credential the caller withheld
  // — or REJECTED outright. Withhold the key for validate, then put the null
  // back. Same fix as ts/js/go makeOptions.
  //
  // Suppliedness cannot be recovered after validate, hence here, and it must
  // tell an ABSENT auth from a present null: containsKey rather than a null
  // check on the value, which cannot distinguish them.
  final authSuppressed =
      options is Map && options.containsKey('auth') && null == options['auth'];

  // User option maps are cloned first — their (possibly narrow) literal
  // types must not constrain the merged structures.
  dynamic opts = vs.merge([{}, cfgopts, vs.clone(mergeOptions)]);

  if (authSuppressed && opts is Map) {
    opts.remove('auth');
  }

  opts = vs.validate(opts, optspec);

  // Restore the suppression the optspec default would otherwise erase.
  if (authSuppressed && opts is Map) {
    opts['auth'] = null;
  }

  // Resolve a templated base URL (e.g. https://{tenant_id}.hanko.io).
  // Every placeholder must resolve to a non-empty value: from options.server
  // (user), else the Config default. A placeholder that resolves to '' is a
  // construction ERROR in live mode — the URL cannot work — but in test mode
  // substitutes the deterministic value `test-<name>` so offline tests need no
  // configuration. The SDK constructor has no error return, so a missing
  // required variable THROWS: construction-time misconfiguration.
  final baseVal = vs.getprop(opts, 'base');
  if (baseVal is String && baseVal.contains('{')) {
    final testmode = true == vs.getpath(opts, 'test.active') ||
        true == vs.getpath(opts, 'feature.test.active');
    final server = vs.getprop(opts, 'server') ?? {};
    final sdkname = (vs.getpath(config, 'main.name') ?? 'SDK').toString();

    opts['base'] = baseVal.replaceAllMapped(
      RegExp(r'\{([A-Za-z0-9_]+)\}'),
      (m) {
        final name = m.group(1) as String;
        final raw = vs.getprop(server, name);
        final val = raw is String ? raw : '';
        if ('' == val) {
          if (testmode) {
            return 'test-' + name;
          }
          throw UnivecError(
            'server_var_required',
            "$sdkname: the server variable '$name' is required: the API base "
            "URL is '$baseVal' — pass { 'server': { '$name': '...' } } in the "
            'SDK options',
          );
        }
        return val;
      },
    );
  }

  final sys = vs.getprop(opts, 'system');
  if (sys is Map) {
    sys['fetch'] = sysFetch;
  } else {
    opts['system'] = {'fetch': sysFetch};
  }

  final cleanKeys =
      (vs.getpath(opts, 'clean.keys') ?? 'key,token,id').toString();

  final parts = <String>[];
  for (final part in cleanKeys.split(',')) {
    final trimmed = part.trim();
    if ('' != trimmed) {
      parts.add(vs.escre(trimmed));
    }
  }
  final keyre = parts.join('|');

  // Resolve the feature add-order: an explicit List order (above) wins;
  // otherwise order the map test-first, then the remaining names sorted, so
  // the outcome is deterministic and `test` is always the base transport.
  if (0 == featureorder.length) {
    final featureMap = vs.getprop(opts, 'feature') ?? {};
    final names = <String>[];
    for (final it in vs.items(featureMap)) {
      names.add(it[0].toString());
    }
    names.sort();
    if (names.contains('test')) {
      featureorder.add('test');
      for (final n in names) {
        if ('test' != n) {
          featureorder.add(n);
        }
      }
    } else {
      featureorder.addAll(names);
    }
    // Station special case, mirroring test's: its transport wrap must
    // sit immediately outside the base transport (inside retry/cache/
    // netsim), so map-form activation hoists it to just after test -
    // or first, when no test entry exists. Without this the sorted
    // default would init station last and wrap OUTSIDE the recording
    // features, turning its wire-truth events into fiction.
    if (featureorder.contains('station')) {
      featureorder.remove('station');
      final ti = featureorder.indexOf('test');
      featureorder.insert(-1 == ti ? 0 : ti + 1, 'station');
    }
  }

  opts['__derived__'] = {
    'clean': {
      'keyre': '' == keyre ? null : keyre,
    },
    'featureorder': featureorder,
  };

  return opts;
}
