// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (dart/lib/host.dart)
// Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// The host: the lifecycle state machine (section 5), extension points
/// (section 6), and resource capture (section 8).
///
/// TWO RULES SHAPE EVERY METHOD BELOW.
///
/// Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
/// never interleaved; a transition triggered from inside a lifecycle
/// callback is `plugin_reentrant`. A hard rule, because it is the only way
/// the semantics can be identical in Go, in Ruby and in single-threaded
/// JavaScript.
///
/// Reconciliation is EAGER (section 18's portability budget). A transition
/// settles by running the state machine to a fixed point, not by suspending
/// on a promise. NOTHING HERE RETURNS A `Future`, and that is the decision
/// dart most invites you to get wrong: an `async` host would make every
/// transition a scheduling point, and section 5.2's "one at a time, in call
/// order" would become a claim about a microtask queue rather than about
/// the code.
library;

import 'types.dart' as t;
import 'ref.dart' as r;
import 'catalog.dart';
import 'config.dart' as config;
import 'capability.dart' as cap;
import 'depend.dart' as dep;
import 'export.dart' as ex;
import 'order.dart' as ord;
import 'point.dart' as pt;

/// One registered instance. The INTERNAL record: a plugin sees `Inst`.
class Entry {
  final String ref;
  final dynamic def;
  String status;
  int pos;
  final int seq;
  Map<String, dynamic> options;
  final Map<String, dynamic> state = {};
  dynamic order;
  List<String> unmet = [];
  final List<void Function()> scope = [];

  /// Section 11.4's ALWAYS-RELUCTANT rebinding made concrete: the provider
  /// ref this instance's activation actually chose, per requirement name.
  /// Re-ranking on every question silently re-points a live consumer at any
  /// better newcomer, and then losing the provider it was really using does
  /// not restart it.
  Map<String, String> selected = {};

  final List<pt.Binding> bindings = [];
  final Map<String, dynamic> exports = {};
  final List<dynamic> provides = [];
  Host? inner;
  bool barred = false;

  Entry(this.ref, this.def, this.status, this.pos, this.seq, this.options,
      this.order);
}

/// What a definition's callbacks see. Deliberately not the internal record:
/// a plugin that could reach `status` could also write it.
class Inst {
  final Host host;
  final Entry _entry;
  final String ref;
  final String name;
  final String tag;

  Inst(this.host, this._entry)
      : ref = _entry.ref,
        name = r.parseRef(_entry.ref)['name'] as String,
        tag = r.parseRef(_entry.ref)['tag'] as String;

  Map<String, dynamic> get options => _entry.options;
  Map<String, dynamic> get state => _entry.state;

  /// Foreign resources the host did not hand out are registered explicitly
  /// (section 8.3); host calls are recorded automatically.
  ///
  /// SYMMETRIC WITH `acquire`, and it has to be: `open` counts the resources
  /// CURRENTLY HELD, so an entry that is registered and then unwound must
  /// leave the count where it found it.
  void release(void Function() fn) {
    // Section 8.3: "`inst.release` outside `activate` is
    // `plugin_release_scope`". `intransition` is true in `define` too, and a
    // scope entry registered there is never unwound.
    if (host.phase != 'activate') {
      t.fail('plugin_release_scope', 'release called outside activate');
    }
    var done = false;
    _entry.scope.add(() {
      if (done) return;
      done = true;
      host.open--;
      fn();
    });
    host.open++;
  }

  /// The synthetic counter the driver owns, so "what is open" is data rather
  /// than an assertion each port words differently.
  ///
  /// Returns its own release, so a plugin can hand one back early. The scope
  /// still holds the entry and unwinding it twice is a no-op - releasing
  /// early must not make teardown wrong.
  void Function() acquire() {
    // Section 8.1: resources are "acquired during `activate` - the scope's
    // actual job". Same reason as `release` above.
    if (host.phase != 'activate') {
      t.fail('plugin_release_scope', 'acquire called outside activate');
    }
    var done = false;
    void rel() {
      if (done) return;
      done = true;
      host.open--;
    }

    _entry.scope.add(rel);
    host.open++;
    return rel;
  }

  /// Bind into a host point. Declared in `define`; the host inserts it only
  /// after `activate` returns successfully (section 8.1), which is why a
  /// failing activate leaves no live binding behind.
  ///
  /// Section 12 has carried `plugin_bind_scope` - "binding declared outside
  /// `define`" - since before anything raised it, and it was the half nobody
  /// wrote: a binding added from `activate` went live without being part of
  /// the loaded definition, and a deactivate/activate cycle appended it
  /// again.
  void bind(String point, pt.BindingFn fn, [dynamic band]) {
    if (host.phase != 'define') {
      t.fail('plugin_bind_scope', 'bind called outside define: $point',
          {'ref': ref, 'point': point});
    }
    if (!host.hasPoint(point)) {
      t.fail('plugin_point_unknown', 'no such point: $point', {'point': point});
    }
    _entry.bindings.add(pt.Binding(ref, point, fn, t.asInt(band) ?? 0));
  }

  /// Published for other plugins and for the application (section 11).
  void export(String key, dynamic value) => _entry.exports[key] = value;

  /// What this instance can do for others (section 11.1).
  void provides(dynamic prov) => _entry.provides.add(prov);

  /// Where this binding landed (section 6.6) - the plugin-side counterpart
  /// to a host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact
  /// available. Verification tells a plugin it was misplaced; a pin (section
  /// 7) stops the misplacement from being expressible at all. The two are
  /// not substitutes.
  Map<String, dynamic> position(String point) => host.positionOf(ref, point);

  /// AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER ONE OWNS
  /// THE INNER ONE'S LIFETIME. Registering the teardown in the instance
  /// scope is what makes that true rather than aspirational.
  Host nest([dynamic nestopts]) {
    if (!host.intransition) {
      t.fail('plugin_release_scope', 'nest called outside a lifecycle callback');
    }
    final inner = Host(nestopts);
    // NOT counted: `open` must read the same before and after a nested host
    // is created.
    _entry.scope.add(() => inner.close());
    _entry.inner = inner;
    return inner;
  }
}

class Host {
  final dynamic _opts;
  final String _dependency;

  /// Set for the duration of a bulk teardown, so `held` knows this is a
  /// coordinated operation rather than an ad-hoc deactivation.
  bool _coordinated = false;

  final Catalog catalog;
  final List _reserved;
  final Map<String, dynamic> _points;

  final Map<String, Entry> _inst = {};
  final List<String> _log = [];

  /// Section 14: the lifecycle event record. `seq` distinguishes ONE
  /// INCARNATION of stripe$test from the next, which is the whole reason it
  /// is not `pos` (section 4 rule 4).
  final List<dynamic> _events = [];
  int _seqn = 0;
  int open = 0;
  bool intransition = false;

  /// WHICH callback is running, not merely that one is. Section 8.1 puts
  /// resource capture in `activate` and 8.3 says `release` outside
  /// `activate` is `plugin_release_scope` - and `intransition` alone cannot
  /// tell `activate` from `define`, so it admitted an acquire in `define`
  /// whose scope `unload` would never unwind.
  String? phase;

  Host([dynamic options])
      : _opts = options ?? <String, dynamic>{},
        _dependency = (t.get(options, 'dependency') ?? 'restart') as String,
        catalog = (t.get(options, 'catalog') ?? makeCatalog()) as Catalog,
        _reserved = (t.get(options, 'reserved') ?? []) as List,
        _points = Map<String, dynamic>.from(
            (t.get(options, 'points') ?? <String, dynamic>{}) as Map);

  bool hasPoint(String name) => _points.containsKey(name);

  // --- observation ---------------------------------------------------

  /// Introspection NEVER advances the state (section 5.2). A status page
  /// must not be a way to accidentally import twenty packages.
  Map<String, dynamic> list() {
    final out = <String, dynamic>{};
    for (final ref in _refs()) {
      out[ref] = _inst[ref]!.status;
    }
    return out;
  }

  Entry? instance(dynamic ref) => _inst[r.canonRef(ref)];

  List<dynamic> trace() => List<dynamic>.from(_events);

  Map<String, dynamic> observable([dynamic result]) => {
        'status': list(),
        'open': open,
        'log': List<String>.from(_log),
        'result': result,
      };

  List<String> _refs() => _inst.keys.toList()..sort();

  // --- the state machine ----------------------------------------------

  void _guard() {
    if (!intransition) return;
    t.fail('plugin_reentrant',
        'transition attempted from inside a lifecycle callback');
  }

  Entry _need(dynamic ref) {
    final rf = r.canonRef(ref);
    final entry = _inst[rf];
    if (entry == null) {
      t.fail('plugin_not_loaded', 'no such instance: $rf', {'ref': rf});
    }
    return entry;
  }

  void _checkReserved(String ref) {
    if (!_reserved.contains(r.refName(ref))) return;
    t.fail('plugin_ref_reserved', 'ref is reserved by the host: $ref',
        {'ref': ref});
  }

  void _run(Entry entry, String callback, String at) {
    final fn = t.get(entry.def, callback);
    _log.add('${entry.ref}:$at');
    _events.add({
      'ref': entry.ref,
      'event': at,
      'seq': entry.seq,
      'status': entry.status
    });
    if (fn is! Function) return;

    intransition = true;
    phase = at;
    try {
      (fn as dynamic)(Inst(this, entry));
    } catch (e) {
      // Section 12: `plugin_define_failed` and its three siblings are "a
      // callback raised; wraps the cause". AN ERROR THAT ALREADY CARRIES A
      // CODE KEEPS IT - the code is the error's identity, and a plugin
      // raising `store_unreachable` must not have it rewritten. Only a
      // code-less error is wrapped.
      if (t.codeOf(e) != '') rethrow;
      t.fail('plugin_${at}_failed',
          '${entry.ref} raised in $at: ${t.messageOf(e)}',
          {'ref': entry.ref, 'cause': t.messageOf(e)});
    } finally {
      intransition = false;
      phase = null;
    }
  }

  /// AUTO-TAGGING IS EXPLICIT (section 4 rule 3). `declare('stripe', {'tag':
  /// '?'})` assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns the
  /// assigned pair. Without `'?'`, a collision is an error.
  String _autotag(String name) {
    for (var n = 1;; n++) {
      final cand = r.formatRef(name, '$n');
      if (!_inst.containsKey(cand)) return cand;
    }
  }

  Entry declare(dynamic ref, [dynamic spec]) {
    spec ??= <String, dynamic>{};
    if (t.get(spec, 'tag') == '?') {
      ref = _autotag(r.refName(r.canonRef(ref)));
    }
    final rf = r.canonRef(ref);
    if (!t.truthy(t.get(spec, 'hostowned'))) _checkReserved(rf);

    final defname = (t.get(spec, 'definition') ?? r.refName(rf)) as String;
    final definition = catalog.get(defname);
    if (definition == null) {
      t.fail('plugin_unknown_definition', 'not in catalog: $defname',
          {'name': defname});
    }

    final existing = _inst[rf];
    if (existing != null) {
      // Section 4 rule 1: a pair addresses at most one instance.
      // Re-declaring the SAME definition is the idempotent case; a different
      // one is a duplicate, not a silent overwrite (seneca) and not an
      // impossibility (sdkgen).
      if (t.get(existing.def, 'name') != t.get(definition, 'name')) {
        t.fail('plugin_ref_duplicate', 'instance already declared: $rf',
            {'ref': rf});
      }
      return existing;
    }

    final pos = t.get(spec, 'pos');
    final entry = Entry(
        rf,
        definition,
        'declared',
        pos == null ? _inst.length : pos as int,
        _seqn,
        Map<String, dynamic>.from(
            (t.get(spec, 'options') ?? <String, dynamic>{}) as Map),
        t.get(spec, 'order'));
    _seqn++;
    _inst[rf] = entry;
    return entry;
  }

  /// Section 9.1: a host that reserves a name MUST still be able to declare
  /// the instance it reserved - "The host declares those instances itself,
  /// after the user merge, and always wins."
  ///
  /// THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit: no
  /// language here can tell the embedding host from a plugin holding the
  /// same host object. What reservation protects is CONFIGURATION -
  /// documents, overlays, `VOXGIG_PLUGIN_*`, construction options and
  /// ordinary declare/load/options - and all of that still checks.
  Entry hostdeclare(dynamic ref, [dynamic spec]) {
    _guard();
    final merged = Map<String, dynamic>.from(
        (spec ?? <String, dynamic>{}) as Map);
    merged['hostowned'] = true;
    return declare(ref, merged);
  }

  Entry load(dynamic ref, [dynamic spec]) {
    _guard();
    spec ??= <String, dynamic>{};
    final entry = declare(ref, spec);
    if (entry.status != 'declared') return entry; // idempotent trivially

    final options = t.get(spec, 'options');
    if (options != null) {
      entry.options = Map<String, dynamic>.from(options as Map);
    }
    try {
      _run(entry, 'define', 'define');
    } catch (_) {
      entry.status = 'failed';
      rethrow;
    }
    entry.status = 'loaded';

    // AT LOAD, and before anything runs: a cycle through restart-causing
    // requirements does not settle, and the only safe time to report a
    // non-terminating reconcile is before it starts (section 11.3).
    // `provides` is populated by `define`, which has just run, so this is
    // the first moment the graph is complete.
    try {
      dep.checkCycle(_graphNodes());
    } catch (_) {
      entry.status = 'failed';
      rethrow;
    }
    return entry;
  }

  /// The requirement graph as plain data, for the pure detector.
  List<dep.GraphNode> _graphNodes() => _refs()
      .map((rf) => dep.GraphNode(
          rf,
          _inst[rf]!.provides.map((p) => t.get(p, 'name') as String).toList(),
          dep.requirements(_inst[rf]!.options)))
      .toList();

  Entry activate(dynamic ref) {
    _guard();
    final entry = _need(ref);
    if (entry.status == 'live') return entry; // no-op returning success

    if (entry.status == 'failed') {
      t.fail('plugin_bad_state', 'instance has failed: ${entry.ref}',
          {'ref': entry.ref});
    }
    // Section 9.6: `active: false` bars the instance from running, and the
    // bar is on the INSTANCE rather than on the apply that set it. `ready`
    // reaches this through `activate`, so one guard covers both verbs the
    // design names.
    if (entry.barred) {
      t.fail('plugin_inactive',
          'instance is barred by active: false: ${entry.ref}',
          {'ref': entry.ref});
    }
    if (entry.status == 'declared') load(entry.ref);

    // A declared requirement that is not live means `pending`: activation is
    // a STANDING REQUEST, not a one-shot event.
    final unmet = _unmetOf(entry);
    if (unmet.isNotEmpty) {
      entry.unmet = unmet;
      entry.status = 'pending';
      return entry;
    }

    try {
      _run(entry, 'activate', 'activate');
    } catch (_) {
      // Unwind whatever the partial activation captured, in reverse.
      _unwind(entry);
      entry.status = 'failed';
      rethrow;
    }
    // Section 11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
    // later question - the cascade, `hold`, `unmet` - reads it back rather
    // than re-ranking, which is what "always-reluctant" means.
    for (final req in dep.requirements(entry.options)) {
      _chosen(entry, req, true);
    }
    entry.status = 'live';
    _reconcile();
    return entry;
  }

  Entry deactivate(dynamic ref) {
    _guard();
    final entry = _need(ref);
    if (entry.status == 'loaded' || entry.status == 'declared') return entry;

    // Section 5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
    if (entry.status == 'failed') {
      t.fail('plugin_bad_state', 'instance has failed: ${entry.ref}',
          {'ref': entry.ref});
    }

    if (entry.status == 'pending') {
      // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section 5.2). It
      // never reached activate, so it holds no scope and no live bindings;
      // running the definition's deactivate there would be teardown without
      // matching setup, which plugins are not written to survive and which
      // could fail an instance that had done nothing wrong. It cannot fail.
      entry.status = 'loaded';
      entry.unmet = [];
      return entry;
    }

    _held(entry);
    _cascade(entry, {});
    _teardown(entry);
    entry.status = 'loaded';
    _reconcile();
    return entry;
  }

  /// The live half of leaving `live`: the callback, then the scope.
  void _teardown(Entry entry) {
    try {
      _run(entry, 'deactivate', 'deactivate');
    } catch (_) {
      _unwind(entry);
      entry.status = 'failed';
      rethrow;
    }
    _releaseCheck(entry, _unwind(entry));
  }

  void unload(dynamic ref) {
    _guard();
    final entry = _need(ref);
    if (entry.status == 'live' || entry.status == 'pending') {
      // Section 5.2: ANY failure during a transition lands the instance in
      // `failed`, with the scope STILL FULLY UNWOUND - and the instance
      // STAYS REGISTERED, because `failed` is a state an operator has to be
      // able to see.
      if (entry.status == 'live') {
        _held(entry);
        _cascade(entry, {});
        _teardown(entry);
      }
      entry.status = 'loaded';
    }
    if (entry.status == 'loaded' || entry.status == 'failed') {
      try {
        _run(entry, 'close', 'close');
      } finally {
        _inst.remove(entry.ref);
      }
      return;
    }
    _inst.remove(entry.ref);
  }

  /// Runs the whole forward path in one call (section 5.1).
  Entry ready(dynamic ref) {
    _guard();
    final rf = r.canonRef(ref);
    if (!_inst.containsKey(rf)) declare(rf);
    if (_inst[rf]!.status == 'declared') load(rf);
    return activate(rf);
  }

  /// Bindings go live only when activation succeeds (section 8.1), so the
  /// teardown is the exact inverse: reverse order, always.
  ///
  /// Returns the errors the scope raised. Section 8.3: "A failing release
  /// does not stop the rest. Every entry runs, in reverse order, whatever
  /// any of them does; the errors are collected and raised as one
  /// `plugin_release_failed`."
  ///
  /// A selection belongs to ONE activation (section 11.4). Leaving `live` by
  /// any door drops it, so the next activation ranks afresh - keeping it
  /// would make a consumer prefer a provider it never actually ran against.
  List<Object> _unwind(Entry entry) {
    entry.selected = {};
    final errors = <Object>[];
    for (var i = entry.scope.length - 1; i >= 0; i--) {
      try {
        entry.scope[i]();
      } catch (e) {
        errors.add(e);
      }
    }
    entry.scope.clear();
    return errors;
  }

  /// Section 8.3: "A failed release ends the instance in `failed`, exactly
  /// as a failed callback does (5.2) - a release that raised may have
  /// leaked, and an instance that may be holding resources it cannot account
  /// for must not be reactivated."
  void _releaseCheck(Entry entry, List<Object> errors) {
    if (errors.isEmpty) return;
    entry.status = 'failed';
    final causes = errors.map(t.messageOf).toList();
    t.fail(
        'plugin_release_failed',
        'release failed for ${entry.ref}: ${causes.join('; ')}',
        {'ref': entry.ref, 'cause': causes});
  }

  /// A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1). A bare
  /// string is shorthand for `{name}`. A ref satisfies too, because a host
  /// that genuinely needs a specific instance should not have to invent a
  /// capability for it.
  List<String> _unmetOf(Entry entry) => dep
      .requirements(entry.options)
      .where(dep.gatesActivation)
      .where((req) => _providersOf(req).isEmpty)
      .map((req) => t.get(req, 'name') as String)
      .toList();

  /// Section 11.4's always-reluctant selection, and the ONE place a provider
  /// is picked for a live instance. If this instance already selected a
  /// provider for `req` and that provider is STILL a candidate, it keeps it
  /// - a better-ranked newcomer does not take it.
  ///
  /// `remember` is false for the questions asked ABOUT an instance rather
  /// than BY it: introspection must not create a binding.
  String? _chosen(Entry entry, dynamic req, bool remember) {
    final cands = _providersOf(req);
    if (cands.isEmpty) return null;
    final name = t.get(req, 'name') as String;
    final held = entry.selected[name];
    if (held != null && cands.any((c) => t.get(c, 'ref') == held)) return held;
    final pick = t.get(cands[0], 'ref') as String;
    if (remember) entry.selected[name] = pick;
    return pick;
  }

  /// The instances currently SELECTED for this one's restart-causing
  /// requirements. A BINDING IS TO AN INSTANCE, not to a capability (section
  /// 11.1): the selected one going away restarts a `static` consumer even
  /// though a survivor is available.
  List<String> _boundProviders(Entry entry) {
    final out = <String>[];
    for (final req in dep.requirements(entry.options)) {
      if (!dep.restartsOnLoss(req)) continue;
      final ref = _chosen(entry, req, false);
      if (ref != null && !out.contains(ref)) out.add(ref);
    }
    return out;
  }

  /// Live instances whose selected provider is `ref` and which would be
  /// restarted by losing it.
  List<String> _consumersOf(String ref) => _refs()
      .where((rf) =>
          rf != ref &&
          _inst[rf]!.status == 'live' &&
          _boundProviders(_inst[rf]!).contains(ref))
      .toList();

  /// Section 11.3's `hold` asks a DIFFERENT question from the cascade, and
  /// reading it off `_consumersOf` answered the cascade's.
  ///
  /// The cascade wants the edges that RESTART - mandatory-static and
  /// optional-static - because a restart is what it performs. `hold` says
  /// "deactivating a REQUIRED instance is `plugin_dependency_held`", and
  /// required is cardinality: `gatesActivation`, not `restartsOnLoss`. The
  /// two sets differ in both directions and each difference was a real bug.
  ///
  /// A MANDATORY-DYNAMIC consumer was excluded, so the strictest policy let
  /// a provider go that a live consumer could not do without - `dynamic`
  /// promises survival of a SWAP, and under `hold` there is no swap, so the
  /// consumer falls back to `pending`.
  ///
  /// An OPTIONAL-STATIC consumer was included, so `hold` refused a
  /// deactivation on behalf of an instance that had said in writing it does
  /// not need the thing.
  List<String> _holdersOf(String ref) => _refs().where((rf) {
        final c = _inst[rf]!;
        if (rf == ref || c.status != 'live') return false;
        return dep.requirements(c.options).any((req) =>
            dep.gatesActivation(req) && _chosen(c, req, false) == ref);
      }).toList();

  List<dynamic> _providersOf(dynamic req) {
    final cands = <dynamic>[];
    final name = t.get(req, 'name');
    final want = r.canon(name);
    for (final ref in _refs()) {
      final target = _inst[ref]!;
      if (target.status != 'live') continue;
      // A ref satisfies directly.
      if (ref == want) {
        cands.add({
          'ref': ref,
          'pos': target.pos,
          'provides': {'name': name}
        });
        continue;
      }
      for (final prov in target.provides) {
        if (t.get(prov, 'name') == name) {
          cands.add({'ref': ref, 'pos': target.pos, 'provides': prov});
        }
      }
    }
    return cap.resolveCapability(req, cands);
  }

  /// CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).
  ///
  /// The cascade is part of the provider's own deactivation and runs BEFORE
  /// the provider's `deactivate` callback and scope unwind, so a consumer's
  /// teardown can still call the thing it depends on - flushing a buffer to
  /// the store it is about to lose is exactly what a `deactivate` callback
  /// is for, and a cascade that fired after the provider was already gone
  /// would make that impossible.
  void _cascade(Entry provider, Map<String, bool> seen) {
    if (seen[provider.ref] == true) return;
    seen[provider.ref] = true;

    for (final rf in _consumersOf(provider.ref)) {
      final consumer = _inst[rf]!;
      if (consumer.status != 'live') continue;
      _cascade(consumer, seen); // deepest-first
      _demote(consumer);
    }
  }

  /// Leaving `live` for `pending` - or for `failed`, because section 5.2
  /// says ANY failure during a transition lands the instance there. Marking
  /// it `pending` handed it straight back to `_reconcile`, which would
  /// activate it again the moment the provider returned.
  void _demote(Entry entry) {
    var bad = false;
    try {
      _run(entry, 'deactivate', 'deactivate');
    } catch (_) {
      bad = true;
    }
    final errors = _unwind(entry);
    if (bad || errors.isNotEmpty) {
      entry.status = 'failed';
      return;
    }
    entry.status = 'pending';
    entry.unmet = _unmetOf(entry);
  }

  /// The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
  /// TEARDOWN. In a bulk operation that is removing the holders too -
  /// `close`, or an `apply` plan whose own steps deactivate them - it is
  /// suspended for exactly those holders, and the teardown still runs
  /// consumers before providers.
  void _held(Entry entry) {
    if (_dependency != 'hold' || _coordinated) return;
    final holders = _holdersOf(entry.ref);
    if (holders.isEmpty) return;
    t.fail(
        'plugin_dependency_held',
        'instance is required by live consumers: ${entry.ref}',
        {'ref': entry.ref, 'holders': holders});
  }

  /// EAGER reconciliation: run to a fixed point rather than scheduling.
  ///
  /// Two directions, and both are the reason `pending` exists. Activation is
  /// a STANDING REQUEST, not a one-shot event.
  void _reconcile() {
    var moved = true;
    var rounds = 0;
    while (moved) {
      moved = false;
      rounds++;
      if (rounds > 1000) break;

      // Losses first, so a cascade settles in one pass rather than
      // alternating with re-activations.
      for (final rf in _refs()) {
        final entry = _inst[rf];
        if (entry == null || entry.status != 'live') continue;
        // POLICY IS PER REQUIREMENT, not per instance (section 11.3). A
        // `dynamic` requirement whose provider is gone leaves the consumer
        // LIVE and notified.
        final lost = dep
            .requirements(entry.options)
            .where(dep.gatesActivation)
            .where((q) => _providersOf(q).isEmpty)
            .toList();
        if (lost.isEmpty) continue;
        if (!lost.any(dep.restartsOnLoss)) continue;
        _demote(entry);
        moved = true;
      }

      for (final rf in _refs()) {
        final entry = _inst[rf];
        if (entry == null || entry.status != 'pending') continue;
        if (_unmetOf(entry).isNotEmpty) continue;
        try {
          _run(entry, 'activate', 'activate');
          entry.status = 'live';
          entry.unmet = [];
        } catch (_) {
          _unwind(entry);
          entry.status = 'failed';
        }
        moved = true;
      }
    }
  }

  // --- ordering --------------------------------------------------------

  List<String> order([String? point]) {
    // Sorted by declaration SEQUENCE, which is what makes the section 7
    // sort's fall-through deterministic in a language whose maps have no
    // meaningful order. Section 7 breaks ties by `pos`; two instances CAN
    // share one - `declare` defaults `pos` to the registry size, so an
    // unload followed by a fresh declare reuses a surviving instance's - and
    // past that this was falling through to map order. `seq` is that order,
    // made explicit.
    final live = _inst.keys.where((rf) => _inst[rf]!.status == 'live').toList();
    live.sort((a, b) => _inst[a]!.seq.compareTo(_inst[b]!.seq));
    final bindings = live
        .map((rf) => ord.OrderNode(rf, _inst[rf]!.pos, _inst[rf]!.order))
        .toList();
    final spec = point == null ? null : _points[point];
    return ord.resolveOrder(bindings, spec == null ? null : t.get(spec, 'pin'));
  }

  // --- points ----------------------------------------------------------

  /// Live bindings on a point, in resolved order. Recomputed on any change
  /// to the live set (section 7) rather than cached at startup - the bug a
  /// host discovers only when something deactivates in production.
  List<pt.Binding> _bound(String point) {
    final out = <pt.Binding>[];
    for (final ref in order(point)) {
      final entry = _inst[ref]!;
      // The band is the INSTANCE's ordering block (section 7), stamped by
      // the host. A plugin passing its own would be ranking itself above the
      // order its document declared.
      final band = t.asInt(t.get(entry.order ?? {}, 'band')) ?? 0;
      for (final b in entry.bindings) {
        if (b.point == point) out.add(b.withBand(band));
      }
    }
    return out;
  }

  dynamic _pointSpec(String point, String want) {
    final spec = _points[point];
    if (spec == null) {
      t.fail('plugin_point_unknown', 'no such point: $point', {'point': point});
    }
    final kind = t.get(spec, 'kind');
    if (want == 'hook') {
      // A point with no declared kind is a hook, which is what makes `{}`
      // the minimal point declaration.
      if (kind != null && kind != 'hook') {
        t.fail('plugin_point_kind', 'point is not a hook: $point',
            {'point': point, 'kind': kind});
      }
      return spec;
    }
    if (kind != want) {
      t.fail('plugin_point_kind', 'point is not a $want: $point',
          {'point': point, 'kind': kind});
    }
    return spec;
  }

  dynamic emit(String point, [dynamic arg]) {
    final spec = _pointSpec(point, 'hook');
    return pt.pointEmit(
        _bound(point), (t.get(spec, 'mode') ?? 'emit') as String, arg);
  }

  dynamic call(String point, [dynamic arg]) {
    final spec = _pointSpec(point, 'chain');
    final base = t.get(spec, 'base') ?? (dynamic a) => a;
    return pt.compose(_bound(point), base as dynamic Function(dynamic))(arg);
  }

  dynamic provider(String point, [dynamic arg]) {
    final spec = _pointSpec(point, 'provider');
    final pick = pt.pointProvider(_bound(point), spec);
    if (pick.winner == null) return t.get(spec, 'default');
    return pick.winner!.fn(null, arg);
  }

  /// The losers are VISIBLE rather than silently ignored (section 6.3).
  List<String> shadowed(String point) {
    final spec = _points[point];
    if (spec == null) return [];
    return pt.pointProvider(_bound(point), spec).shadowed;
  }

  dynamic exports(String spec) {
    final all = <ex.Exported>[];
    for (final ref in _refs()) {
      final entry = _inst[ref]!;
      // Exports of a `loaded` (not live) instance are VISIBLE (11).
      if (entry.status == 'declared' || entry.status == 'failed') continue;
      for (final k in t.sortedKeys(entry.exports)) {
        all.add(ex.Exported(ref, k, entry.exports[k]));
      }
    }
    return ex.resolveExport(spec, all);
  }

  /// The live providers of a capability, best-first (section 11.1).
  List<String> capability(String name) {
    final cands = <dynamic>[];
    for (final ref in _refs()) {
      final entry = _inst[ref]!;
      if (entry.status != 'live') continue;
      for (final prov in entry.provides) {
        if (t.get(prov, 'name') == name) {
          cands.add({'ref': ref, 'pos': entry.pos, 'provides': prov});
        }
      }
    }
    return cap
        .resolveCapability({'name': name}, cands)
        .map((c) => t.get(c, 'ref') as String)
        .toList();
  }

  // --- documents -------------------------------------------------------

  dynamic _shapeOf(String ref) {
    final definition = catalog.get(r.refName(ref));
    return definition == null ? null : t.get(definition, 'shape');
  }

  /// Section 9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
  /// changed, and move activation state to match", with the stated ordering
  /// - "deactivations and unloads first (reverse load order), then loads,
  /// then activations in load order".
  ///
  /// FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
  /// document once, which never looked at instances the new document had
  /// DROPPED - so an integration removed from a config reload stayed live
  /// with its bindings and resources.
  void apply(dynamic doc, [dynamic profile]) {
    _guard();
    profile ??= t.get(_opts, 'profile');
    final norm = config.normalizeConfig({
      'doc': doc,
      'profile': profile,
      'keys': t.get(_opts, 'keys'),
      'reserved': _reserved
    });

    final want = norm['order'] as List<String>;
    final defaults = t.get(_opts, 'defaults') ?? {};
    final optionsof = <String, Map<String, dynamic>>{};
    for (final ref in want) {
      optionsof[ref] = config.resolveOptions({
        'ref': ref,
        'doc': doc,
        'profile': profile,
        'shape': _shapeOf(ref),
        'hostdefaults': t.get(defaults, r.refName(ref))
      });
    }

    // Should this ref be LIVE after the apply? False for a ref the document
    // declares lazy or inactive AND for one it does not name at all - which
    // is what makes "unload what is gone" and "unload what was toggled off"
    // one rule rather than two.
    bool wantlive(String ref) {
      final ent = t.get(norm['instance'], ref);
      return ent != null &&
          t.truthy(t.get(ent, 'active')) &&
          t.get(ent, 'start') == 'eager';
    }

    // --- phase 1: deactivations and unloads, REVERSE load order ---------
    final drop = _inst.keys
        .where((rf) => _inst[rf]!.status != 'declared' && !wantlive(rf))
        .toList();
    // Highest `pos` first, ref-descending for a tie, so a consumer declared
    // after its provider goes down first.
    drop.sort((a, b) {
      final pa = _inst[a]!.pos, pb = _inst[b]!.pos;
      return pa == pb ? b.compareTo(a) : pb.compareTo(pa);
    });
    for (final ref in drop) {
      unload(ref);
    }

    // --- phase 2: declare and patch EVERYTHING, in load order -----------
    for (final ref in want) {
      final ent = t.get(norm['instance'], ref);
      // NO OPTIONS HERE, and the omission is the fix rather than an
      // oversight. `declare` ADOPTS the options map it is handed as the
      // instance's own, so passing the resolved map made target and
      // source THE SAME MAP in the refill below - which cleared its own
      // source and left a first-time instance with no options at all.
      // `declare` makes its own empty map and the refill fills it, so
      // both paths are now one path.
      declare(ref, {
        'order': t.get(ent, 'order'),
        'pos': t.get(ent, 'pos')
      });
      final entry = _inst[ref]!;
      // The bar is REASSERTED ON EVERY APPLY, in both directions - a
      // document that turns the instance back on clears it, which is the
      // whole point of a config switch.
      entry.barred = !t.truthy(t.get(ent, 'active'));
      // REFILL rather than REBIND. A definition's callbacks close over the
      // options map they were handed at `define`.
      entry.options
        ..clear()
        ..addAll(optionsof[ref]!);
      entry.order = t.get(ent, 'order');
      entry.pos = t.get(ent, 'pos') as int;
    }

    // --- phase 3: loads, in load order ----------------------------------
    // ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances is
    // twenty map entries and no executed code" (9.6).
    for (final ref in want) {
      if (wantlive(ref)) load(ref);
    }

    // --- phase 4: activations, in load order ----------------------------
    for (final ref in want) {
      if (wantlive(ref)) activate(ref);
    }
  }

  void options(dynamic ref, dynamic patch) {
    _guard();
    final entry = _need(ref);
    final previous = Map<String, dynamic>.from(entry.options);
    final merged = Map<String, dynamic>.from(previous);
    if (patch != null) merged.addAll((patch as Map).cast<String, dynamic>());
    final resolved = config.resolveOptions({
      'ref': entry.ref,
      'shape': _shapeOf(entry.ref),
      'doc': <String, dynamic>{},
      'patch': merged
    });
    entry.options
      ..clear()
      ..addAll(resolved);
    if (entry.status != 'live') return;

    final reconfigure = t.get(entry.def, 'reconfigure');
    if (reconfigure is Function) {
      intransition = true;
      try {
        (reconfigure as dynamic)(Inst(this, entry), entry.options, previous);
      } finally {
        intransition = false;
      }
    } else {
      // Always correct and sometimes expensive; `reconfigure` exists to make
      // the common case cheap (section 9.4).
      deactivate(entry.ref);
      activate(entry.ref);
    }
  }

  void close() {
    // A bulk teardown removing the holders too, so `hold` is suspended for
    // exactly those holders (section 11.3) - while the consumers-first
    // cascade still runs, which is the half that matters.
    _coordinated = true;
    try {
      for (final rf in _refs().reversed) {
        unload(rf);
      }
    } finally {
      _coordinated = false;
    }
  }

  /// The same record section 6.6 gives a plugin about itself, reachable from
  /// outside for the corpus.
  Map<String, dynamic> positionOf(dynamic ref, String point) {
    final entry = _inst[r.canon(ref)];
    if (entry == null) {
      t.fail('plugin_not_loaded', 'no such instance: $ref', {'ref': ref});
    }
    final ranked = order(point);
    final index = ranked.indexOf(entry.ref);
    return {
      'index': index,
      'count': ranked.length,
      // Section 6.2 composes b1(b2(b3(base))) with the FIRST binding
      // OUTERMOST, so these are not index 0 and index count-1 the other way
      // round.
      'outermost': index == 0,
      'innermost': index == ranked.length - 1,
    };
  }

  void define(dynamic definition) => catalog.add(definition);
}

Host makeHost([dynamic options]) => Host(options);
