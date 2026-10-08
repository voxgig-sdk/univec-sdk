
import { nom } from '@voxgig/apidef'

import {
  cmp,
  each,
  File,
  Content,
  entityCollection,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
} from '@voxgig/sdkgen'

import { dartStringLiteral } from './utility_dart'


// The canary sweep (port of the ts TestClean component): canaries in every
// credential slot, every diagnostic feature capturing into a sink, a real
// operation through every outcome, and every emitted string searched for the
// canaries and their encoded forms. Dart has no reflection, so the candidate
// operations are listed at generation time.
const TestClean = cmp(function TestClean(props: any) {
  const { model } = props.ctx$

  const auth = {
    suppressed: isAuthSuppressed(model),
    where: resolveAuthIn(model),
    name: 'header' === resolveAuthIn(model)
      ? resolveAuthName(model).toLowerCase() : resolveAuthName(model),
    basic: isHttpBasicAuth(model),
  }

  const rank: Record<string, number> = { list: 0, load: 1 }
  const candidates: string[] = []
  each(entityCollection(model))
    .filter((e: any) => false !== e.active)
    .forEach((ent: any) => {
      const ops = Object.keys(ent.op || {})
        .filter((op) => ['list', 'load', 'create', 'update', 'patch', 'remove'].includes(op))
        .sort((a, b) => (rank[a] ?? 2) - (rank[b] ?? 2))
      for (const op of ops) {
        const params = pointParams(ent.op[op]).map(dartStringLiteral).join(', ')
        candidates.push(
          `  _Candidate('${ent.name}.${op}', <String>[${params}],\n` +
          `      (sdk, match, ctrl) => sdk.${nom(ent, 'Name')}().${op}(match, ctrl),\n` +
          `      (sdk, match, callopts) =>\n` +
          `          sdk.${nom(ent, 'Name')}().stream('${op}', {'reqmatch': match}, callopts)),`)
      }
    })

  File({ name: 'clean_test.dart' }, () => Content(render(nom(model.const, 'Name'), auth, candidates)))
})


// Every path parameter an operation's points declare, as the generated
// config carries them (point.args.params[].name).
function pointParams(op: any): string[] {
  const vals = (x: any): any[] => null == x ? [] : Array.isArray(x) ? x : Object.values(x)
  const names: string[] = []
  for (const pt of vals(op?.points)) {
    if (null == pt || false === pt.a) continue
    for (const p of vals(pt.g?.params)) {
      if (null != p && false !== p.a && 'string' === typeof p.n && !names.includes(p.n)) {
        names.push(p.n)
      }
    }
  }
  return names
}


function render(
  Name: string,
  auth: { suppressed: boolean, where: string, name: string, basic: boolean },
  candidates: string[],
): string {
  return `// ${Name} SDK secret-redaction sweep. GENERATED — do not edit.
//
// Every credential slot holds a canary, every diagnostic feature this SDK
// carries captures into a sink, a real operation runs through every outcome,
// and every string that leaves the SDK is searched for the canaries and their
// encoded forms. The second test switches clean off and requires the canary
// to show, so a sweep that cannot see a leak fails rather than passing.

import 'dart:convert';

import 'harness.dart';
import 'feature/harness.dart' show hasFeature;

import '../lib/${Name}SDK.dart';
import '../lib/${Name}Error.dart';
import '../lib/feature/base/BaseFeature.dart';
import '../lib/utility/ErrUtility.dart' show errmsg;

// Generated: the credential's wire placement is fixed when the SDK is built.
// The dart runtime always carries the credential in the Authorization
// header (its prepareAuth is header-only), so that is the slot asserted.
const AUTH = <String, dynamic>${JSON.stringify(auth)};

const CANARY = <String, String>{
  'apikey': 'CANARY-APIKEY-k9x2m7q4p1',
  'secret': 'CANARY-SECRET-w3e8r5t2y6',
  'header': 'CANARY-HEADER-z1x4c7v0b3',
  'value': 'CANARY-VALUE-n5m8b2v9c4',
};

const MASK = '[redacted]';

// Every form a canary can travel in.
final List<String> FORMS = _forms();

List<String> _forms() {
  final out = <String>[];
  for (final v in CANARY.values) {
    out.add(v);
    out.add(base64Encode(utf8.encode(v)));
    out.add(Uri.encodeComponent(v));
  }
  out.add(base64Encode(utf8.encode(CANARY['apikey']! + ':' + CANARY['secret']!)));
  return out;
}

class Sink {
  final String name;
  final String text;
  Sink(this.name, this.text);
}

// Header maps keep the caller's spelling; the assertion should not care.
dynamic header(dynamic map, String name) {
  if (map is! Map) {
    return null;
  }
  for (final k in map.keys) {
    if (k.toString().toLowerCase() == name.toLowerCase()) {
      return map[k];
    }
  }
  return null;
}

List<String> leaks(String text) => FORMS.where((f) => text.contains(f)).toList();

String? jsonText(dynamic val) {
  try {
    return jsonEncode(val);
  } catch (_e) {}
  try {
    return jsonEncode((val as dynamic).toJSON());
  } catch (_e) {}
  return null;
}

List<Sink> forms(String name, dynamic val) {
  final out = <Sink>[];
  final json = jsonText(val);
  if (null != json) {
    out.add(Sink(name + ':json', json));
  }
  try {
    out.add(Sink(name + ':string', val.toString()));
  } catch (_e) {}
  if (val is ${Name}Error) {
    out.add(Sink(name + ':message', val.message));
  }
  return out;
}

// Captures the serialised context from inside the pipeline: what a hook
// author would hand to a logger.
class CaptureFeature extends BaseFeature {
  final List<Sink> _sinks;

  CaptureFeature(this._sinks) {
    name = 'capture';
    version = '0.0.1';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) => null;

  void _capture(String hook, dynamic ctx) {
    _sinks.addAll(forms('ctx@' + hook, ctx.toJSON()));
    _sinks.add(Sink('ctx@' + hook + ':string', ctx.toString()));
  }

  @override
  dynamic PreRequest(dynamic ctx) {
    _capture('PreRequest', ctx);
    return null;
  }

  @override
  dynamic PreResponse(dynamic ctx) {
    _capture('PreResponse', ctx);
    return null;
  }

  @override
  dynamic PreUnexpected(dynamic ctx) {
    _capture('PreUnexpected', ctx);
    return null;
  }
}

typedef Respond = dynamic Function(String url, dynamic fetchdef);

class Scenario {
  final String name;
  final Respond respond;
  Scenario(this.name, this.respond);
}

Map<String, dynamic> response(int status, dynamic data,
    [Map<String, String>? headers]) {
  final h = <String, dynamic>{'content-type': 'application/json'};
  headers?.forEach((k, v) => h[k] = v);
  return {
    'status': status,
    'statusText': status < 400 ? 'OK' : 'ERR',
    'headers': h,
    'body': 'body',
    'json': () => data,
  };
}

final SCENARIOS = <Scenario>[
  Scenario('ok', (url, fd) => response(200, {'id': 'i1', 'name': 'n1'},
      {'x-session-token': 'RESP-TOKEN-a1b2c3d4e5'})),
  Scenario('notfound', (url, fd) => response(404, {'error': 'no such record'})),
  Scenario('server', (url, fd) => response(500, {'error': 'boom'})),
  Scenario('transport',
      (url, fd) => throw Exception('socket hang up (URL was: "' + url + '")')),
  Scenario('notjson', (url, fd) => {
        'status': 200,
        'statusText': 'OK',
        'headers': <String, dynamic>{},
        'body': '<html>',
        'json': () => throw FormatException('Unexpected token < in JSON'),
      }),
  // A provider failing with the SDK's own error, its code quoting the key.
  Scenario('coded',
      (url, fd) => throw ${Name}Error('refused_' + CANARY['apikey']!, 'refused')),
];

// bare builds the client with no clean block at all, as most callers do.
${Name}SDK makeSdk(Scenario scenario, List<Sink> sinks,
    [Map<String, dynamic>? cleanopts, List<BaseFeature>? extra, bool bare = false]) {
  dynamic Function(dynamic) capture(String name) => (dynamic rec) {
        sinks.addAll(forms(name, rec));
        return null;
      };

  final feature = <String, dynamic>{};
  if (hasFeature('log')) {
    feature['log'] = {'active': true, 'logger': capture('log')};
  }
  if (hasFeature('debug')) {
    feature['debug'] = {'active': true, 'onEntry': capture('debug')};
  }
  if (hasFeature('audit')) {
    feature['audit'] = {'active': true, 'sink': capture('audit')};
  }
  if (hasFeature('telemetry')) {
    feature['telemetry'] = {'active': true, 'exporter': capture('telemetry')};
  }
  if (hasFeature('cost')) {
    feature['cost'] = {'active': true, 'sink': capture('cost')};
  }
  if (hasFeature('metrics')) {
    feature['metrics'] = {'active': true};
  }
  if (hasFeature('clienttrack')) {
    feature['clienttrack'] = {'active': true};
  }

  final clean = <String, dynamic>{'values': CANARY['value']};
  cleanopts?.forEach((k, v) => clean[k] = v);

  return ${Name}SDK(<String, dynamic>{
    'apikey': CANARY['apikey'],
    'secret': CANARY['secret'],
    'headers': {'X-Custom-Token': CANARY['header']},
    if (!bare) 'clean': clean,
    'feature': feature,
    'extend': [CaptureFeature(sinks), ...(extra ?? <BaseFeature>[])],
    'utility': {
      'fetcher': (dynamic ctx, dynamic url, dynamic fetchdef) async =>
          scenario.respond(url.toString(), fetchdef),
    },
  });
}

class _Candidate {
  final String name;
  final List<String> params;
  final Future<dynamic> Function(dynamic sdk, dynamic match, dynamic ctrl) run;
  final Stream<dynamic> Function(dynamic sdk, dynamic match, dynamic callopts) stream;
  const _Candidate(this.name, this.params, this.run, this.stream);
}

class _Target {
  final _Candidate op;
  final Map<String, dynamic> match;
  const _Target(this.op, this.match);
}

// Every entity operation this SDK offers, list and load first.
final CANDIDATES = <_Candidate>[
${candidates.join('\n')}
];

// The first operation that completes against a plain 200: with no
// arguments, else with every path parameter its points declare filled in.
Future<_Target?> usableOp() async {
  for (final c in CANDIDATES) {
    final filled = <String, dynamic>{for (final p in c.params) p: 'p1'};
    for (final match in [<String, dynamic>{}, filled]) {
      final plain = ${Name}SDK(<String, dynamic>{
        'apikey': CANARY['apikey'],
        'utility': {
          'fetcher': (dynamic ctx, dynamic url, dynamic fd) async =>
              response(200, {'id': 'i1'}),
        },
      });
      try {
        await c.run(plain, Map<String, dynamic>.of(match), <String, dynamic>{});
        return _Target(c, match);
      } catch (_e) {
        continue;
      }
    }
  }
  return null;
}

// An error with a code of its own, as a library a hook calls might throw.
class HookError implements Exception {
  final String code;
  final String message;
  HookError(this.code, this.message);

  @override
  String toString() => code + ': ' + message;
}

// A feature that throws from inside the pipeline, quoting the request it
// saw: an error makeError never handled.
class ThrowFeature extends BaseFeature {
  final bool unexpected;

  ThrowFeature([this.unexpected = false]) {
    name = 'throwhook';
    version = '0.0.1';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) => null;

  @override
  dynamic PreResponse(dynamic ctx) {
    throw HookError('hook_' + CANARY['apikey']!, 'hook saw ' + jsonEncode(ctx.spec));
  }

  // Fired from the operation's catch block, before its cleaning.
  @override
  dynamic PreUnexpected(dynamic ctx) {
    if (unexpected) {
      throw HookError('hook_' + CANARY['apikey']!, 'hook saw ' + jsonEncode(ctx.spec));
    }
    return null;
  }
}

// A stream that fails while the caller iterates it, quoting a credential.
class StreamThrowFeature extends BaseFeature {
  StreamThrowFeature() {
    name = 'streamthrow';
    version = '0.0.1';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) => null;

  @override
  dynamic PreDone(dynamic ctx) {
    ctx.result.stream = () async* {
      throw Exception('stream saw ' + CANARY['apikey']!);
    };
    return null;
  }
}

// A stream that succeeds, so the pipeline's terminal step never runs.
class StreamOkFeature extends BaseFeature {
  StreamOkFeature() {
    name = 'streamok';
    version = '0.0.1';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) => null;

  @override
  dynamic PreDone(dynamic ctx) {
    final data = ctx.result.resdata;
    final items = data is List ? data : (null == data ? [] : [data]);
    ctx.result.stream = () async* {
      yield* Stream.fromIterable(items);
    };
    return null;
  }
}

Future<dynamic> drive(dynamic sdk, _Target target, Map<String, dynamic> ctrl,
    List<Sink> sinks) async {
  // A caller may keep the record it passed rather than read ctrl['explain'].
  final held = ctrl['explain'];
  dynamic out;
  dynamic err;
  try {
    out = await target.op.run(sdk, Map<String, dynamic>.of(target.match), ctrl);
  } catch (e) {
    err = e;
  }
  if (null != err) {
    sinks.addAll(forms('error', err));
  }
  if (null != out) {
    sinks.addAll(forms('result', out));
  }
  if (null != ctrl['explain']) {
    sinks.addAll(forms('explain', ctrl['explain']));
  }
  if (null != held && !identical(held, ctrl['explain'])) {
    sinks.addAll(forms('explain:held', held));
  }
  return err;
}

class _Variant {
  final String name;
  final Map<String, dynamic> Function() ctrl;
  const _Variant(this.name, this.ctrl);
}

final VARIANTS = <_Variant>[
  _Variant('throw', () => <String, dynamic>{}),
  _Variant('explain', () => <String, dynamic>{'explain': <String, dynamic>{}}),
  _Variant('nothrow',
      () => <String, dynamic>{'throw': false, 'explain': <String, dynamic>{}}),
];

void tests() {
  describe('clean', () {
    test('no credential leaves the SDK in any form', (t) async {
      final target = await usableOp();
      if (null == target) {
        t.skip('no operation of this SDK completes against a plain 200; nothing to sweep');
        return;
      }

      final sinks = <Sink>[];
      final errors = <String, dynamic>{};
      final explains = <String, dynamic>{};

      for (final scenario in SCENARIOS) {
        for (final variant in VARIANTS) {
          final sdk = makeSdk(scenario, sinks);
          final ctrl = variant.ctrl();
          final err = await drive(sdk, target, ctrl, sinks);
          final key = scenario.name + '/' + variant.name;
          if (null != err) {
            errors[key] = err;
          }
          if (null != ctrl['explain']) {
            explains[key] = ctrl['explain'];
          }
          sinks.addAll(forms('sdk', sdk));
        }
      }

      // A credential mistyped as a map is rejected by validation, whose
      // message quotes the value it rejected; with and without a clean block.
      for (final cleanblock in [
        <String, dynamic>{
          'clean': {'values': CANARY['value']}
        },
        <String, dynamic>{},
      ]) {
        dynamic rejected;
        try {
          ${Name}SDK(<String, dynamic>{
            'apikey': {'value': CANARY['apikey']},
            ...cleanblock,
          });
        } catch (e) {
          rejected = e;
        }
        ok(null != rejected, 'a credential mistyped as a map should be rejected');
        sinks.addAll(forms('rejected', rejected));
        sinks.add(Sink('rejected:message', errmsg(rejected)));
      }

      // An error a feature hook throws, quoting the request, skips makeError,
      // and so does the explain record it leaves behind.
      for (final unexpected in [false, true]) {
        final hooked = makeSdk(SCENARIOS[0], sinks, null, [ThrowFeature(unexpected)]);
        final hookerr = await drive(hooked, target,
            <String, dynamic>{'explain': <String, dynamic>{}}, sinks);
        ok(null != hookerr, 'the throwing hook should fail the operation');
      }

      // Iterating a stream runs inside the same catch path as the operation,
      // and the explain record the caller passed is cleaned however it ends.
      for (final entry in <String, List<BaseFeature>>{
        'stream': [StreamThrowFeature()],
        'stream-ok': [StreamOkFeature()],
        'stream-plain': [],
      }.entries) {
        final streamed = makeSdk(SCENARIOS[0], sinks, null, entry.value);
        final explain = <String, dynamic>{};
        dynamic streamerr;
        try {
          await for (final _ in target.op.stream(streamed,
              Map<String, dynamic>.of(target.match), {
            'ctrl': {'explain': explain}
          })) {}
        } catch (e) {
          streamerr = e;
        }
        ok(('stream' == entry.key) == (null != streamerr),
            entry.key + ': only the failing stream throws');
        if (null != streamerr) {
          sinks.addAll(forms(entry.key, streamerr));
        }
        ok(explain.isNotEmpty, entry.key + ': the explain record was not filled');
        sinks.addAll(forms(entry.key + ':explain', explain));
      }

      // Most callers pass no clean block; the defaults alone must mask.
      for (final scenario in [SCENARIOS[1], SCENARIOS[3]]) {
        final bare = makeSdk(scenario, sinks, null, null, true);
        await drive(bare, target,
            <String, dynamic>{'explain': <String, dynamic>{}}, sinks);
        sinks.addAll(forms('bare', bare));
      }

      // The raw path returns its failure rather than throwing it. The key
      // rides in the query, as a caller of an endpoint wanting it there sends it.
      final raw = await makeSdk(SCENARIOS[3], sinks).direct({
        'path': 'raw',
        'query': {'api_key': CANARY['apikey']},
      });
      ok(false == raw['ok'] && null != raw['err'],
          'a transport failure should fail direct()');
      sinks.addAll(forms('direct', raw['err']));

      final leaked = <String>[];
      for (final s in sinks) {
        final found = leaks(s.text);
        if (found.isNotEmpty) {
          leaked.add(s.name + ' [' + found.join(', ') + ']');
        }
      }

      print('clean: swept ' +
          sinks.length.toString() +
          ' surface(s), ' +
          leaked.length.toString() +
          ' leak(s)');

      equal(0, leaked.length, 'credential leaked through: ' + leaked.join('; '));

      // The positive half: the slot the credential travelled in is masked,
      // and an unregistered token in a response header is masked by name.
      final notfound = errors['notfound/throw'];
      ok(null != notfound, 'the 404 scenario must throw');
      equal(404, notfound.status);
      if (true != AUTH['suppressed']) {
        final spec = notfound.spec ?? {};
        final authval = header(spec['headers'], 'authorization');
        ok(authval.toString().endsWith(MASK), 'authorization: ' + authval.toString());
      }
      equal(MASK, header(notfound.spec['headers'], 'x-custom-token'));

      final explained = explains['ok/explain'] ?? {};
      ok(null != explained['result'], 'the explain record should carry the result');
      equal(MASK, header(explained['result']['headers'], 'x-session-token'));
    });

    test('the sweep can see a leak: clean switched off shows the credential',
        (t) async {
      final target = await usableOp();
      if (null == target) {
        t.skip('no operation of this SDK completes against a plain 200; nothing to sweep');
        return;
      }

      final sinks = <Sink>[];
      final sdk = makeSdk(SCENARIOS[1], sinks, {'active': false});
      final err = await drive(sdk, target, <String, dynamic>{}, sinks);
      ok(null != err);

      // Explaining a failure must not cost it its error.
      final explained = await drive(makeSdk(SCENARIOS[1], <Sink>[], {'active': false}),
          target, <String, dynamic>{'explain': <String, dynamic>{}}, <Sink>[]);
      equal(err.message, explained?.message, 'with clean off, explain lost the error');

      final leaked = sinks.where((s) => leaks(s.text).isNotEmpty).toList();
      ok(leaked.isNotEmpty, 'with clean off, nothing showed the canary: the sweep is blind');

      if (true != AUTH['suppressed']) {
        final text = jsonText(err.spec) ?? '';
        ok(
            text.contains(CANARY['apikey']!) ||
                text.contains(base64Encode(
                    utf8.encode(CANARY['apikey']! + ':' + CANARY['secret']!))),
            'the raw spec should carry the credential when clean is off');
      }
    });
  });
}
`
}


export {
  TestClean
}
