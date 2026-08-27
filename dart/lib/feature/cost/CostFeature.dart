// ignore_for_file: non_constant_identifier_names

import '../../utility/voxgig_struct.dart' as vs;

import '../base/BaseFeature.dart';

// Cost tracking and spend budget. Uses BOTH seams, which is the point of
// the feature: money is spent per HTTP ATTEMPT (a retried call is charged
// again, because the upstream API charges it again), but it is owed by an
// OPERATION. So the transport wrap prices each attempt, and PreDone
// attributes the running total to `<entity>.<op>` and to the caller
// (`ctrl.actor`, the same actor the audit feature records).
//
// The price of an attempt comes from the first source that answers: a
// response header (`header` x `perUnit`), the rate table (`rates`, keyed
// '<entity>.<op>' / '<op>' / '*'), then the flat `unit`. A body figure
// (`path` x `perUnit`, e.g. 'usage.total_tokens') is read at PreDone
// instead, from the already-parsed result. A body figure describes the
// whole call, so it REPLACES the per-attempt estimate rather than adding
// to it.
//
// `budget` caps total spend. With `onBudget` = 'deny' a further operation
// is refused at PrePoint, before an endpoint is resolved and before
// anything reaches the network.
//
// ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
// cache is charged for money that was never spent. Aggregates live on the
// client track (`cost`).
class CostFeature extends BaseFeature {
  dynamic _client;
  final Map<dynamic, dynamic> _pending = {};
  int _seq = 0;

  CostFeature() {
    version = '0.0.1';
    name = 'cost';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];
    _pending.clear();
    _seq = 0;

    final limit = _limit();
    final track = _client.track;
    if (null == track['cost']) {
      track['cost'] = <String, dynamic>{
        'currency': options['currency'] ?? 'USD',
        'total': <String, dynamic>{
          'calls': 0,
          'attempts': 0,
          'amount': 0,
          'reported': 0,
          'estimated': 0,
        },
        'ops': <String, dynamic>{},
        'actors': <String, dynamic>{},
        'budget': <String, dynamic>{
          'limit': limit,
          'spent': 0,
          'remaining': limit,
          'exceeded': false,
        },
        'last': null,
      };
    }

    if (!active) {
      return null;
    }

    final self = this;
    final utility = ctx.utility;
    final inner = utility.fetcher;

    utility.fetcher = (dynamic ctx2, dynamic url, dynamic fetchdef) async {
      return self._charge(ctx2, url, fetchdef, inner);
    };
    return null;
  }

  // Budget gate. Runs before endpoint resolution, so a refused call costs
  // nothing at all.
  @override
  dynamic PrePoint(dynamic ctx) {
    if (!active) {
      return null;
    }

    // Mark the context as running through the pipeline, so _charge knows a
    // PreDone is coming and does not commit the spend itself.
    var pending = _pending[ctx];
    if (null == pending) {
      pending = _pending[ctx] = _newPending();
    }
    pending['piped'] = true;

    final limit = _limit();
    if (0 >= limit) {
      return null;
    }

    final cost = _client.track['cost'];
    if (cost['total']['amount'] < limit) {
      return null;
    }

    cost['budget']['exceeded'] = true;

    if ('deny' != options['onBudget']) {
      return null;
    }

    final err = ctx.error(
        'cost_budget',
        'Cost budget of ' +
            limit.toString() +
            ' ' +
            cost['currency'].toString() +
            ' is spent (' +
            cost['total']['amount'].toString() +
            ' ' +
            cost['currency'].toString() +
            ' used)');
    // Short-circuit endpoint resolution; the pipeline surfaces this error.
    ctx.out['point'] = err;
    return err;
  }

  Future<dynamic> _charge(
      dynamic ctx, dynamic url, dynamic fetchdef, dynamic inner) async {
    dynamic res;
    var threw = false;

    // A throwing transport still costs an attempt. Without this, a run of
    // connection-level failures under `retry` (which catches the throw and
    // tries again) would be charged nothing at all, and an onBudget =
    // 'deny' ceiling could never stop it.
    try {
      res = await Future.value(inner(ctx, url, fetchdef));
    } catch (err) {
      threw = true;
      res = err;
    }

    final priced = _price(ctx, threw ? null : res);
    final amount = priced['amount'];
    final source = priced['source'];

    final cost = _client.track['cost'];

    var pending = _pending[ctx];
    if (null == pending) {
      pending = _pending[ctx] = _newPending();
    }

    pending['attempts'] = pending['attempts'] + 1;

    // Accumulated here, committed once at PreDone. Adding each attempt to
    // the running total and then subtracting it again when a body figure
    // supersedes it loses precision to catastrophic cancellation
    // (5 + (0.01 - 5) is not 0.01 in binary floating point).
    //
    // Reported and estimated are kept apart per ATTEMPT, not per operation:
    // a 503 priced from the rate table followed by a 200 carrying the cost
    // header is part estimate, part reported, and collapsing both into the
    // final attempt's category would corrupt the split.
    pending['amount'] = pending['amount'] + amount;
    final bucket = ('header' == source || 'body' == source) ? 'reported' : 'estimated';
    pending[bucket] = pending[bucket] + amount;
    pending['source'] = source;

    cost['total']['attempts'] = cost['total']['attempts'] + 1;

    // direct() and graphql() reach the transport without dispatching any
    // pipeline hooks - no PrePoint to gate on, and no PreDone to commit.
    // Their spend is committed here instead, or it would never be counted
    // and could run past an onBudget = 'deny' ceiling indefinitely.
    // `piped` is set by PrePoint, so its absence is the signal.
    if (true != pending['piped']) {
      _commit(ctx, pending, '_', 'direct');
      _pending.remove(ctx);
    }

    if (threw) {
      throw res;
    }

    return res;
  }

  Map<String, dynamic> _newPending() {
    return <String, dynamic>{
      'attempts': 0,
      'amount': 0,
      'reported': 0,
      'estimated': 0,
      'source': 'none',
      'piped': false,
    };
  }

  // Attribute the operation's spend once the call is finished.
  @override
  dynamic PreDone(dynamic ctx) {
    _finish(ctx, true);
    return null;
  }

  // A failed operation still spent the money. When the pipeline throws,
  // PreDone never runs, so without this the attempts are counted and the
  // spend is not, and a budget could never see the cost of a failed call.
  // Whichever hook fires first consumes the pending entry, so it commits
  // exactly once.
  @override
  dynamic PreUnexpected(dynamic ctx) {
    _finish(ctx, false);
    return null;
  }

  void _finish(dynamic ctx, bool done) {
    if (!active) {
      return;
    }
    if (!_pending.containsKey(ctx)) {
      return;
    }
    final pending = _pending[ctx];
    _pending.remove(ctx);

    // A FAILED operation that made no attempt never reached the network:
    // PrePoint creates the pending entry to mark the context as piped, and
    // then the budget gate refuses the call (rbac, or an unresolvable
    // endpoint, short-circuits just as early). Committing it would count a
    // call that never happened and file a zero-amount record as `last`.
    //
    // A SUCCEEDED operation that made no attempt is the opposite case: it
    // was served from the cache. That is a real call, and the fact that it
    // cost nothing is the whole point of ordering cost inside the cache.
    if (!done && 0 == pending['attempts']) {
      return;
    }

    final entity = (null == ctx.op ? '_' : (ctx.op.entity ?? '_')).toString();
    final opname = (null == ctx.op ? '_' : (ctx.op.name ?? '_')).toString();

    _commit(ctx, pending, entity, opname);
  }

  // Commit one operation's spend: totals, budget, per-op and per-actor
  // attribution, and the record. Shared by _finish and the raw-request path
  // in _charge, which has no PreDone to reach.
  void _commit(dynamic ctx, dynamic pending, String entity, String opname) {
    final cost = _client.track['cost'];

    var amount = pending['amount'];
    var reported = pending['reported'];
    var estimated = pending['estimated'];
    var source = pending['source'];

    // A body figure prices the whole call, so it replaces the per-attempt
    // estimate rather than adding to it - and, being server-stated, the
    // whole amount counts as reported.
    final body = _body(ctx);
    if (null != body) {
      amount = body;
      reported = body;
      estimated = 0;
      source = 'body';
    }

    _spend(cost, amount, reported, estimated);

    final actor = (ctx.ctrl is Map ? ctx.ctrl['actor'] : null) ??
        options['actor'] ??
        'anonymous';

    cost['total']['calls'] = cost['total']['calls'] + 1;
    _bump(cost['ops'], entity + '.' + opname, amount);
    _bump(cost['actors'], actor.toString(), amount);

    _seq = _seq + 1;
    final record = <String, dynamic>{
      'seq': _seq,
      'entity': entity,
      'op': opname,
      'actor': actor,
      'amount': amount,
      'currency': cost['currency'],
      'source': source,
      'attempts': pending['attempts'],
    };
    cost['last'] = record;

    final sink = options['sink'];
    if (sink is Function) {
      // A sink must never break the call it is reporting on.
      try {
        sink(record);
      } catch (_e) {}
    }
  }

  // Price one attempt: a reported header figure, else the rate table, else
  // the flat unit.
  Map<String, dynamic> _price(dynamic ctx, dynamic res) {
    final header = options['header'];
    if (header is String && '' != header) {
      final v = _header(res, header);
      if (null != v) {
        return <String, dynamic>{'amount': v * _perUnit(), 'source': 'header'};
      }
    }

    final rate = _rate(ctx);
    if (null != rate) {
      return <String, dynamic>{'amount': rate, 'source': 'table'};
    }

    final unit = options['unit'];
    if (unit is num && 0 != unit) {
      return <String, dynamic>{'amount': unit, 'source': 'unit'};
    }

    return <String, dynamic>{'amount': 0, 'source': 'none'};
  }

  // The rate table uses the same lookup grammar as rbac's rules:
  // '<entity>.<op>', then '<op>', then '*'.
  num? _rate(dynamic ctx) {
    final rates = options['rates'] ?? {};

    var entity = _entname(ctx.entity);
    if ('' == entity) {
      entity = (null == ctx.op ? '' : (ctx.op.entity ?? '')).toString();
    }
    final opname = (null == ctx.op ? '' : (ctx.op.name ?? '')).toString();

    for (final key in [entity + '.' + opname, opname, '*']) {
      final r = vs.getprop(rates, key);
      if (r is num) {
        return r;
      }
    }
    return null;
  }

  // A usage figure from the parsed result body, priced by perUnit. Read
  // here, not at the transport seam, because the body is consumed once.
  num? _body(dynamic ctx) {
    final path = options['path'];
    if (path is! String || '' == path) {
      return null;
    }
    if (null == ctx.result) {
      return null;
    }
    final body = ctx.result.body;
    if (body is! Map) {
      return null;
    }
    final v = vs.getpath(body, path);
    final n = v is num ? v : num.tryParse((v ?? '').toString());
    if (null == n) {
      return null;
    }
    return n * _perUnit();
  }

  void _spend(dynamic cost, num amount, num reported, num estimated) {
    final total = cost['total'];
    total['amount'] = total['amount'] + amount;
    total['reported'] = total['reported'] + reported;
    total['estimated'] = total['estimated'] + estimated;

    final budget = cost['budget'];
    final limit = budget['limit'];
    budget['spent'] = total['amount'];
    if (0 < limit) {
      final left = limit - total['amount'];
      budget['remaining'] = left < 0 ? 0 : left;
      if (total['amount'] >= limit) {
        budget['exceeded'] = true;
      }
    } else {
      budget['remaining'] = 0;
    }
  }

  void _bump(dynamic bucket, String key, num amount) {
    var b = bucket[key];
    if (null == b) {
      b = bucket[key] = <String, dynamic>{'calls': 0, 'amount': 0};
    }
    b['calls'] = b['calls'] + 1;
    b['amount'] = b['amount'] + amount;
  }

  // HTTP header names are case-insensitive and a custom transport keeps
  // conventional casing ('X-Request-Cost'), so scan rather than index.
  num? _header(dynamic res, String name) {
    if (null == res) {
      return null;
    }
    final headers = vs.getprop(res, 'headers');
    if (headers is! Map) {
      return null;
    }
    final lower = name.toLowerCase();
    for (final k in headers.keys) {
      if (k.toString().toLowerCase() == lower) {
        final v = headers[k];
        return v is num ? v : num.tryParse(v.toString());
      }
    }
    return null;
  }

  String _entname(dynamic ent) {
    if (null == ent) {
      return '';
    }
    if (ent is Map) {
      return (vs.getprop(ent, 'name', '') ?? '').toString();
    }
    try {
      return (ent.name ?? '').toString();
    } catch (_e) {
      return '';
    }
  }

  num _perUnit() {
    final p = options['perUnit'];
    return p is num ? p : 0;
  }

  num _limit() {
    final b = options['budget'];
    return b is num ? b : 0;
  }
}
