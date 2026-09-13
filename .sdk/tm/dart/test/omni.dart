// The corpus test runner: vendored @voxgig/omni driven through its NATIVE
// API (`vendor/omni/omni.dart`'s `makeRunner(specref, provider)`), presented
// to the corpus tests in the struct-runner shape they already use
// (`run.spec`, `run.runset`, `run.runsetflags`, `run.client`). No compat
// shim is vendored: the adapter below IS the whole bridge, per language, per
// the vendor-tag rollout (docs/design/vendor-tag-rollout.md, Decision 4). It
// supersedes test/runner.dart (the fused engine) and test/struct_corpus.dart
// (the second, independent engine the struct corpus carried).
//
// Dart-specific decisions, each load-bearing:
//
// 1. THE SDK IS ASYNC AND OMNI IS NOT - the one thing that makes dart
//    different from every other migrated target. `RunPack.runset` is `void`
//    and calls `entrysubject(args)` synchronously; four generated utilities
//    (fetcher, makeRequest, makeResponse, resultBody) answer `Future`, and
//    three of them are corpus-driven. Dart has no way to block on a Future
//    (dart:cli's waitFor was removed in Dart 3), so this resolver drives
//    omni TWICE over the same set:
//
//      PASS A (execute) runs a copy of the set with `out`/`err`/`match`
//      stripped from every entry - so the null flag makes NULLMARK both the
//      expectation and the (collector's) result, and every entry passes by
//      construction. The real subject runs here, exactly once; its return
//      value (Future or not) and any throw are captured, along with omni's
//      own argument list.
//
//      SETTLE awaits each captured Future, then writes each typed Context's
//      observable state back into the ctx map it came from (decision 3).
//
//      PASS B (verify) re-runs the REAL set with a replay subject that
//      returns the settled value (or rethrows the settled error) and splices
//      pass A's mutated argument containers into pass B's, keeping identity
//      so `match: {args: ...}` and `match: {ctx: ...}` read post-run state.
//
//    Every assertion - argument resolution, null normalisation, result
//    comparison, error matching, `match` walking, failure text - is omni's.
//    The passes differ only in which subject omni calls. Upstream follow-up:
//    an async-capable dart runner (so pass A/B collapse into one).
//
// 2. OMNI DOES NOT NORMALISE CLASS INSTANCES; THE RETIRED RUNNER DID.
//    omni's `fixjson` passes a non-Map/List value through untouched, and
//    `deepequal`/`getpath` then see a typed object - so `primary.makeContext`
//    asserting `match: {out: {op: {name: 'create'}}}` would read every leaf
//    as absent. The useful half of the retired runner (its `jsonNorm`) lives
//    on here as `_tojson`, the subject-result conversion: `toJSON()` for the
//    pipeline value classes (Context, Spec, Result, Response, Operation,
//    Point), {name,message,code} for error values, functions dropped, and a
//    cycle guard.
//
// 3. CONTEXTS STAY MAPS ACROSS THE RUNNER. omni sets `entry['ctx']` to the
//    contextified args[0] and `match: {ctx: ...}` reads THROUGH it with
//    `getpath`, which walks Maps and Lists only. A typed Context there would
//    make every ctx assertion read "absent". So the ctx stays an omni map;
//    this resolver materialises the real Context from it at the subject
//    boundary (as the retired runner did), and writes the Context's
//    observable state back into that same map after the call. Call sites keep
//    receiving a Context and need no change. (java's OmniResolver spells the
//    same contract as per-call-site omniCtx/omniSyncCtx because its typed
//    CtxFn cannot be built generically; dart's `makeContext` can.)
//
// 4. ZERO-ARGUMENT ENTRIES. The corpus carries entries with no `in`, `args`
//    or `ctx`, meaning "call the subject with NO value" - struct's
//    `minor/typify` has both `{in: null, out: <T_null>}` and
//    `{out: <T_noval>}`. The vendored dart port distinguishes them natively
//    (`args = [entry.containsKey('in') ? entry['in'] : ABSENT]`), so dart is
//    the java shape: no novalargs spec rewrite, no compat shim. The
//    resolver's ONE boundary conversion is the sentinel swap: omni's ABSENT
//    becomes the dart struct port's own no-value sentinel
//    (`voxgig_struct.pathifyNoArg`, the default of typify/stringify/pathify)
//    on the way in. Sections that want dart's single `null` for a
//    zero-argument entry (the port has no no-value overload for `isnode`,
//    `clone`, `merge`, ...) map it back at their own call site - see
//    struct_test.dart's `_plain`.
//
// 5. THE VENDORED DART PORT AT THIS TAG carries omni#54's match fix
//    (`_match` reads its base directly, no clone - java and go still clone)
//    but NOT the `jsonstr` cycle guard (util.dart has no seen-set). Both
//    only bite on CYCLIC values, so java's decision-3 discipline applies
//    verbatim: typed and potentially cyclic state (a live SDK, a Context)
//    stays OUT of the entry maps - decisions 2 and 3 above are what keep it
//    that way, and `_fail` excludes `ctx` from its entry summary. Recorded
//    here for the next-tag resync, not patched locally.
//
// 6. NO subject-by-name provider hook. The dart SDK COULD serve one
//    (`Utility.byName` / `StructUtility.byName` both answer `dynamic`), but
//    omni consults it only to OVERRIDE an explicitly passed subject when an
//    entry names a `client` - which would discard the per-section adapters
//    the corpus call sites supply. Every call site passes its subject
//    explicitly, so the hook is dead weight at best. DEF.client entries still
//    resolve: the `client` hook below builds another live test SDK, and
//    `_makectx` hands it to the Context as `ctx.client`.

import 'vendor/omni/omni.dart' as omni;

import 'utility.dart' show resolveTestPath;

import '../lib/utility/ErrUtility.dart';
import '../lib/utility/voxgig_struct.dart' as vs;

// The sentinels, under the names the corpus tests already use.
const String NULLMARK = omni.NULLMARK;
const String UNDEFMARK = omni.UNDEFMARK;
const String EXISTSMARK = omni.EXISTSMARK;

// omni's own types, re-exported so the corpus suites and the smoke test
// need not reach into the vendored directory themselves.
typedef Flags = omni.Flags;
typedef OmniError = omni.OmniError;

// Absence, as distinct from a JSON null (see decision 4).
const dynamic ABSENT = omni.ABSENT;
bool isabsent(dynamic val) => omni.isabsent(val);

/// Convert NULLMARK sentinels back into real nulls.
///
/// NOT a delegation to omni's `nullmodifier`, deliberately: omni's RETURNS
/// the replacement value, while the dart struct port's `inject` passes this
/// as its `modify` hook and expects it to MUTATE `parent[key]` in place.
void nullModifier(dynamic val, dynamic key, dynamic parent, [dynamic inj]) {
  if (NULLMARK == val) {
    vs.setprop(parent, key, null);
  } else if (val is String) {
    vs.setprop(parent, key, val.replaceAll(NULLMARK, 'null'));
  }
}

/// What one subject call produced: the value (or the throw), omni's own
/// argument list, and the typed Context materialised for args[0], if any.
class _Capture {
  final List<dynamic> args;

  dynamic ctxmap;
  dynamic ctx;

  dynamic value;
  bool threw = false;
  Object error = '';

  _Capture(this.args);
}

/// The live SDK, wrapped as an omni provider. One instance per makeRunner
/// call; DEF.client entries add more, each registered so `_makectx` can
/// resolve a ctx map's `client` back to the SDK it stands for.
class _Bridge {
  final dynamic client;

  // Providers built by a spec's DEF.client block - the only ones allowed to
  // override a call site's own client. The BASE provider rides on every ctx
  // entry, and letting it win would defeat the sections that deliberately
  // construct a differently-optioned client (makeSpec, prepareAuth).
  final Map<Object, dynamic> _live = Map.identity();

  // Maps omni contextified for the set now running (decision 3).
  final Set<Object> _marks = Set.identity();

  late final omni.Provider provider;

  _Bridge(this.client) {
    provider = omni.Provider(
      // A DEF.client entry becomes another live test SDK. `tester` takes the
      // client options as TESTOPTS, which is where the retired runner put
      // them; nothing in the shared corpus pins the choice (only
      // `primary.check` declares a DEF.client, and dart does not drive it),
      // so the existing behaviour is kept deliberately.
      client: (dynamic options) {
        final sub = _Bridge(client.tester(options ?? {}));
        _live[sub.provider] = sub.client;
        return sub.provider;
      },

      // Client options may reference the runner store.
      inject: (dynamic options, dynamic store) {
        vs.inject(options, store);
        return options;
      },

      // The ctx STAYS an omni map (decision 3); mark it so the subject
      // boundary knows to materialise a real Context from it.
      contextify: (dynamic val) {
        if (val is Map) {
          _marks.add(val);
        }
        return val;
      },

      // Keep the SDK error's code beside its message, so a corpus
      // `match: {err: {code: ...}}` can assert on it, and so the message is
      // the SDK's own rather than Dart's `toString()` prefix. This is what
      // the retired runner's jsonNorm put in the same slot.
      errify: (dynamic err) {
        final out = <String, dynamic>{
          'name': err.runtimeType.toString(),
          'message': errmsg(err),
        };
        final code = errcode(err);
        if ('' != code) {
          out['code'] = code;
        }
        return out;
      },
    );
  }

  void resetmarks() {
    _marks.clear();
  }

  bool isctx(dynamic val) => val is Map && _marks.contains(val);

  /// Build the typed Context a generated utility takes from the ctx MAP omni
  /// handed the subject. A DEF-built provider in the map's `client` slot
  /// resolves back to the live SDK it wraps.
  dynamic makectx(dynamic ctxmap) {
    var sdk = client;

    final found = ctxmap['client'];
    if (found is omni.Provider) {
      final live = _live[found];
      if (null != live) {
        sdk = live;
      }
    }

    final utility = sdk.utility();
    final ctx = utility.makeContext(ctxmap);
    ctx.client = sdk;
    ctx.utility = utility;
    return ctx;
  }
}

/// What the runner returns for one named spec section - the struct-runner
/// shape the corpus call sites already consume. A failing entry throws
/// [OmniError] with the entry named, which fails the harness case.
class Run {
  final dynamic spec;

  /// The live SDK (NOT the omni provider): corpus suites call
  /// `run.client.utility()` on it.
  final dynamic client;

  /// Entries actually driven through omni by this run. The corpus suites
  /// assert on it: a suite that stopped executing the corpus would still be
  /// green, and that is the failure mode this rollout exists to prevent.
  int caseCount = 0;

  final omni.RunPack _pack;
  final _Bridge _bridge;

  Run(this._pack, this._bridge)
      : spec = _pack.spec,
        client = _bridge.client;

  /// A named group of the resolved spec.
  dynamic set(String name) => _pack.set(name);

  /// Run one set of test entries with omni's default flags.
  Future<void> runset(dynamic testspec, [dynamic subject]) =>
      runsetflags(testspec, const omni.Flags(), subject);

  /// Run one set of test entries with explicit flags (see decision 1 for why
  /// this drives omni twice).
  Future<void> runsetflags(dynamic testspec, omni.Flags flags,
      [dynamic subject]) async {
    if (null == subject) {
      throw omni.OmniError('omni: no test subject supplied');
    }

    final caps = <_Capture>[];

    // PASS A: execute. Checks are stripped, so every entry passes and the
    // real subject runs exactly once, for its value or its throw.
    _bridge.resetmarks();
    _pack.runsetflags(_stripchecks(testspec), flags, (List<dynamic> args) {
      caps.add(_call(subject, args));
      return null;
    });

    // SETTLE: await what the SDK deferred, then publish each Context's
    // observable state into the ctx map `match: {ctx: ...}` reads.
    for (final cap in caps) {
      final pending = cap.value;
      if (pending is Future) {
        try {
          cap.value = await pending;
        } catch (err) {
          cap.threw = true;
          cap.error = err;
          cap.value = null;
        }
      }
      if (null != cap.ctx) {
        _syncctx(cap.ctxmap, cap.ctx);
      }
    }

    caseCount += caps.length;

    // PASS B: verify. omni re-runs the REAL set; the replay subject supplies
    // the settled outcome and the mutated arguments.
    var at = 0;
    _pack.runsetflags(testspec, flags, (List<dynamic> args) {
      if (at >= caps.length) {
        throw omni.OmniError(
            'omni: replay ran out of captured results (verify pass drove more '
            'entries than the execute pass)');
      }
      final cap = caps[at++];
      _replayargs(args, cap.args);
      if (cap.threw) {
        throw cap.error;
      }
      return _tojson(cap.value);
    });
  }

  // Call the subject for one entry, capturing everything pass B needs.
  _Capture _call(dynamic subject, List<dynamic> args) {
    final cap = _Capture(args);

    final callargs = <dynamic>[];
    for (final arg in args) {
      // Decision 4: omni's absence becomes the port's own no-value.
      callargs.add(omni.isabsent(arg) ? vs.pathifyNoArg : arg);
    }

    // Decision 3: the entry's ctx/args map becomes a real Context here.
    if (callargs.isNotEmpty && _bridge.isctx(args[0])) {
      cap.ctxmap = args[0];
      cap.ctx = _bridge.makectx(cap.ctxmap);
      callargs[0] = cap.ctx;
    }

    try {
      cap.value = Function.apply(subject, callargs);
    } catch (err) {
      cap.threw = true;
      cap.error = err;
    }

    return cap;
  }
}

/// The struct runner's `makeRunner(testfile, client)` signature, backed by
/// vendored omni. `testfile` is a spec path (resolved against the package
/// root or the test directory - omni's loader does not resolve relative
/// paths itself) or an already-parsed spec value (omni's own capability),
/// which keeps the smoke test free of fixture files.
Run Function(String name, [dynamic store]) makeRunner(
    dynamic testfile, dynamic client) {
  final specref = testfile is String ? resolveTestPath(testfile) : testfile;

  final bridge = _Bridge(client);
  final runner = omni.makeRunner(specref, bridge.provider);

  return (String name, [dynamic store]) =>
      Run(runner.runner(name, store), bridge);
}

// ---------------------------------------------------------------------------
// Pass plumbing
// ---------------------------------------------------------------------------

// A copy of the set with every entry's checks removed, so pass A cannot
// fail: with no `out` the null flag makes NULLMARK the expectation, and the
// collector returns null, which fixjson turns into exactly that. `empty` and
// every other group-level key survive, so a malformed group still fails in
// pass A with omni's own message.
dynamic _stripchecks(dynamic testspec) {
  if (testspec is! Map) {
    return testspec;
  }

  final out = <String, dynamic>{};
  testspec.forEach((key, val) => out['$key'] = val);

  final testset = testspec['set'];
  if (testset is List) {
    out['set'] = testset.map<dynamic>((entry) {
      if (entry is! Map) {
        return entry;
      }
      final stripped = <String, dynamic>{};
      entry.forEach((key, val) {
        if ('out' != key && 'err' != key && 'match' != key) {
          stripped['$key'] = val;
        }
      });
      return stripped;
    }).toList();
  }

  return out;
}

// Write the OBSERVABLE state of a typed context back into the ctx map the
// entry holds, which is where a `match: {ctx: ...}` assertion reads. Exactly
// what the retired runner produced: it put the Context itself in `entry.ctx`
// and normalised the whole match base through jsonNorm, so the assertions
// have always read `Context.toJSON()`.
void _syncctx(dynamic ctxmap, dynamic ctx) {
  if (ctxmap is! Map) {
    return;
  }

  final norm = _tojson(ctx);
  if (norm is! Map) {
    return;
  }

  ctxmap.clear();
  norm.forEach((key, val) => ctxmap[key] = val);
}

// Carry pass A's argument mutations into pass B's argument list. Containers
// are spliced (contents replaced, identity kept) because omni already handed
// the same object to `entry['ctx']` and to the `match` base; anything else is
// assigned. Without this, a subject that mutates its argument - struct's
// setpath and merge, and every ctx-carrying utility - would look inert.
void _replayargs(List<dynamic> into, List<dynamic> from) {
  final count = into.length < from.length ? into.length : from.length;

  for (var index = 0; index < count; index++) {
    final target = into[index];
    final source = from[index];

    if (identical(target, source)) {
      continue;
    }

    if (target is Map && source is Map) {
      target.clear();
      source.forEach((key, val) => target[key] = val);
      continue;
    }

    if (target is List && source is List) {
      target.clear();
      target.addAll(source);
      continue;
    }

    into[index] = source;
  }
}

// Normalise a value to a JSON-like structure (decision 2): class instances
// through toJSON(), error values to {name, message, code}, functions dropped
// (map members) or nulled, cycles marked. Nulls are left alone - omni's own
// fixjson applies the null flag right after this.
dynamic _tojson(dynamic val, [Set<dynamic>? seen]) {
  if (null == val || val is num || val is bool || val is String) {
    return val;
  }

  // omni's own absence marker is a runner value, not a subject result: it
  // must reach fixjson intact or an absent stays as the text "ABSENT".
  if (omni.isabsent(val)) {
    return val;
  }

  seen ??= Set.identity();

  if (val is Map) {
    if (seen.contains(val)) {
      return '[Circular]';
    }
    seen.add(val);
    final out = <String, dynamic>{};
    val.forEach((key, subval) {
      if (subval is! Function) {
        out['$key'] = _tojson(subval, seen);
      }
    });
    seen.remove(val);
    return out;
  }

  if (val is List) {
    if (seen.contains(val)) {
      return '[Circular]';
    }
    seen.add(val);
    final out = val.map<dynamic>((subval) => _tojson(subval, seen)).toList();
    seen.remove(val);
    return out;
  }

  if (iserr(val)) {
    final out = <String, dynamic>{
      'name': val.runtimeType.toString(),
      'message': errmsg(val),
    };
    final code = errcode(val);
    if ('' != code) {
      out['code'] = code;
    }
    return out;
  }

  if (val is Function) {
    return null;
  }

  if (seen.contains(val)) {
    return '[Circular]';
  }

  try {
    seen.add(val);
    final out = _tojson((val as dynamic).toJSON(), seen);
    seen.remove(val);
    return out;
  } catch (_e) {
    seen.remove(val);
    return val.toString();
  }
}
