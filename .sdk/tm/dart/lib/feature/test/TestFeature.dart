// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:math';

import '../../utility/voxgig_struct.dart' as vs;

import '../base/BaseFeature.dart';

const S_NOT_FOUND = 'Not found';

class TestFeature extends BaseFeature {
  dynamic _client;
  int _netcalls = 0;

  TestFeature() {
    version = '0.0.1';
    name = 'test';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};

    final entity = options['entity'];

    _client.mode = 'test';

    // Ensure entity ids are correct.
    vs.walk(entity, before: (k, v, parent, path) {
      if (2 == vs.size(path)) {
        vs.setprop(v, 'id', k);
      }
      return v;
    });

    final self = this;

    // THE MOCK HAS TO AGREE WITH THE MODEL. A point carrying
    // `transform.res: `body.item`` describes an API that answers
    // {"item": {...}}, and the response transform unwraps that key on the way
    // back. Returning the bare payload means the transform unwraps a property
    // that is not there and the caller gets nothing. Mirrors the go/ts/lua/php
    // mocks.
    dynamic envelope(dynamic fctx, dynamic data) {
      if (null == data || null == fctx || null == fctx.point) {
        return data;
      }
      // dart wraps the point in a Point OBJECT (Context._aspoint), so its
      // fields are typed properties, not map keys — vs.getprop on it returns
      // null and the envelope silently never applies.
      final tm = fctx.point.transform;
      final spec = vs.getprop(tm, 'res');
      if (spec is! String) {
        return data;
      }
      // Exactly `body.<key>`; a deeper path is not an envelope this mock can
      // synthesise, so it is left alone rather than guessed at.
      final m = RegExp(r'^`body\.([^`.]+)`$').firstMatch(spec);
      if (null == m) {
        return data;
      }
      return <String, dynamic>{m.group(1)!: data};
    }

    dynamic respond(dynamic fctx, int status, [dynamic data, dynamic res]) {
      final payload = envelope(fctx, data);
      final out = vs.merge([
        <String, dynamic>{
          'status': status,
          'statusText': 'OK',
          'json': () => payload,
          'body': 'not-used',
        },
        vs.getdef(res, {}),
      ]);

      final headers = vs.getprop(out, 'headers', {});
      out['headers'] = headers;

      return out;
    }

    dynamic testFetcher(dynamic fctx, dynamic _fullurl, dynamic _fetchdef) {
      final param = fctx.utility.param;

      final op = fctx.op;
      final entmap = vs.getprop(entity, op.entity, {});

      if ('load' == op.name) {
        final args = self.buildArgs(fctx, op, fctx.reqmatch);
        final found = vs.select(entmap, args);
        final ent = vs.getelem(found, 0);
        if (null == ent) {
          return respond(fctx, 404, null, {'statusText': S_NOT_FOUND});
        } else {
          vs.delprop(ent, r'$KEY');
          final out = vs.clone(ent);
          return respond(fctx, 200, out);
        }
      } else if ('list' == op.name) {
        final args = self.buildArgs(fctx, op, fctx.reqmatch);
        final found = vs.select(entmap, args);
        if (null == found) {
          return respond(fctx, 404, null, {'statusText': S_NOT_FOUND});
        } else {
          for (final ent in found) {
            vs.delprop(ent, r'$KEY');
          }
          final out = vs.clone(found);
          return respond(fctx, 200, out);
        }
      } else if ('update' == op.name) {
        final args = self.buildArgs(fctx, op, fctx.reqdata);
        final found = vs.select(entmap, args);
        final ent = vs.getelem(found, 0);
        if (null == ent) {
          return respond(fctx, 404, null, {'statusText': S_NOT_FOUND});
        } else {
          // Dart's single null stands in for the donor's undefined: merge
          // must not overwrite stored values with absent ones.
          final upddata = <String, dynamic>{};
          if (fctx.reqdata is Map) {
            (fctx.reqdata as Map).forEach((k, v) {
              if (null != v) {
                upddata[k.toString()] = v;
              }
            });
          }
          vs.merge([ent, upddata]);
          vs.delprop(ent, r'$KEY');
          final out = vs.clone(ent);
          return respond(fctx, 200, out);
        }
      } else if ('remove' == op.name) {
        final args = self.buildArgs(fctx, op, fctx.reqmatch);
        final found = vs.select(entmap, args);
        final ent = vs.getelem(found, 0);
        // Remove only the first matched entity. If nothing matches,
        // succeed as a no-op rather than erroring.
        if (null != ent) {
          vs.delprop(entmap, vs.getprop(ent, 'id'));
        }
        return respond(fctx, 200);
      } else if ('create' == op.name) {
        self.buildArgs(fctx, op, fctx.reqdata);
        dynamic id = param(fctx, 'id');
        if (null == id) {
          final rng = Random();
          final h = () => rng.nextInt(0x10000).toRadixString(16);
          id = (h() + h() + h() + h()).padRight(16, '0');
        }

        final ent = vs.clone(fctx.reqdata);
        vs.setprop(ent, 'id', id);
        vs.setprop(entmap, id, ent);
        vs.delprop(ent, r'$KEY');
        final out = vs.clone(ent);
        return respond(fctx, 200, out);
      }

      return null;
    }

    // Optional network behaviour simulation over the mock transport. Enable
    // per test via `SDK.test({ net: { latency, failTimes, ... } })`. When
    // `net` is absent the mock behaves exactly as before (no wrapping), so
    // existing generated tests are unaffected.
    final net = options['net'];
    ctx.utility.fetcher =
        (null == net) ? testFetcher : makeNetsim(net, testFetcher);
    return null;
  }

  // Wrap a transport with simulated network conditions: latency (fixed or
  // {min,max}), a budget of first-N failures (`failTimes` -> `failStatus`),
  // first-N connection errors (`errorTimes`), or a hard `offline` outage.
  // Counter-driven, so simulations are deterministic across a test.
  dynamic makeNetsim(dynamic net, dynamic inner) {
    final self = this;
    self._netcalls = 0;

    int pickLatency() {
      final l = net['latency'];
      if (null == l) {
        return 0;
      }
      if (l is num) {
        return l < 0 ? 0 : l.toInt();
      }
      final min = (l['min'] is num) ? (l['min'] as num).toInt() : 0;
      final max = null == l['max'] ? min : (l['max'] as num).toInt();
      return max <= min ? min : min + ((max - min) >> 1);
    }

    Future<void> sleep(int ms) {
      if (0 >= ms) {
        return Future.value();
      }
      final sleeper = net['sleep'];
      if (sleeper is Function) {
        return Future.value(sleeper(ms)).then((_x) {});
      }
      return Future.delayed(Duration(milliseconds: ms));
    }

    return (dynamic fctx, dynamic url, dynamic fetchdef) async {
      self._netcalls++;
      final call = self._netcalls;

      if (true == net['offline']) {
        await sleep(pickLatency());
        return fctx.error('netsim_offline',
            'Simulated network offline (URL was: "' + url.toString() + '")');
      }
      final errorTimes = net['errorTimes'] is num ? net['errorTimes'] : 0;
      if (call <= errorTimes) {
        await sleep(pickLatency());
        return fctx.error('netsim_conn',
            'Simulated connection error (call ' + call.toString() + ')');
      }
      final failTimes = net['failTimes'] is num ? net['failTimes'] : 0;
      if (call <= failTimes) {
        await sleep(pickLatency());
        final status = null == net['failStatus'] ? 503 : net['failStatus'];
        return <String, dynamic>{
          'status': status,
          'statusText': 'Simulated Failure',
          'body': 'not-used',
          'json': () => null,
          'headers': {},
        };
      }
      await sleep(pickLatency());
      return inner(fctx, url, fetchdef);
    };
  }

  dynamic buildArgs(dynamic ctx, dynamic op, dynamic args) {
    final param = ctx.utility.param;

    final opname = op.name;

    // Pick the entity's own endpoint from config, not a cross-reference from
    // another resource that also returns it — the same rule makePoint falls
    // back to, so the seed-data query is built from the endpoint the request
    // will actually be sent to: a terminal `{id}` marks a record route, and
    // failing that the shallower path wins.
    final points = vs.getpath(
        ctx.config, ['entity', _entname(ctx.entity), 'op', opname, 'points']);
    var point = vs.getelem(points, 0);
    if (points is List) {
      int pointPartsLen(dynamic p) {
        final parts = vs.getprop(p, 'parts');
        return parts is List ? parts.length : 0;
      }

      bool pointTerminalParam(dynamic p) {
        final parts = vs.getprop(p, 'parts');
        if (parts is! List || parts.isEmpty) {
          return false;
        }
        final last = parts[parts.length - 1];
        return last is String && last.startsWith('{');
      }

      for (final cand in points) {
        if (pointTerminalParam(cand) != pointTerminalParam(point)) {
          if (pointTerminalParam(cand)) {
            point = cand;
          }
        } else if (pointPartsLen(cand) < pointPartsLen(point)) {
          point = cand;
        }
      }
    }

    final reqd = vs.transform(
      vs.select(vs.getpath(point, ['args', 'params']), {'reqd': true}),
      ['`\$EACH`', '', '`\$KEY.name`'],
    );

    final qand = <dynamic>[];
    final q = {'`\$AND`': qand};

    for (final k in vs.keysof(args)) {
      if ('id' == k || !vs.isempty(vs.select(reqd, k))) {
        final v = param(ctx, k);
        // Dart's single null stands in for the donor's undefined: an
        // absent match value constrains nothing.
        if (null == v) {
          continue;
        }
        // NOTE: mirrors the donor: op.alias is not present on Operation,
        // so no alias alternates are generated here.
        dynamic qor = [
          {k: v}
        ];

        qor = {'`\$OR`': qor};

        qand.add(qor);
      }
    }

    if (null != ctx.ctrl['explain']) {
      ctx.ctrl['explain']['test'] = {'query': q};
    }

    return q;
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
}
