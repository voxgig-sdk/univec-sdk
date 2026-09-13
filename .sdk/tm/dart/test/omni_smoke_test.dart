// Smoke tests for the vendored omni runner itself: a runner that cannot FAIL
// a bad entry would turn every corpus suite vacuously green, so pin the
// failure paths, not just the happy one. (The dart peer of tm/ts/test/
// omni.test.ts, tm/lua/test/omni_smoke_test.lua and tm/go/test/
// omnismoke_test.go.)
//
// The dart lane pins one thing the other targets need not: the resolver's
// two-pass drive (test/omni.dart, decision 1). An ASYNC subject must be
// driven to the same verdict as a sync one - passing when it settles to the
// expected value, FAILING when it does not, and matching an expected error
// when the Future rejects. Without those three, the async sections of the
// primary corpus could quietly stop asserting anything.

import 'harness.dart';
import 'omni.dart';

import '../lib/UnivecSDK.dart';

// A minimal in-memory spec: no fixture file, no OMNI block (lenient v0, like
// the shared corpus).
dynamic _makespec() => {
      'primary': {
        'smoke': {
          'basic': {
            'set': [
              {'in': 1, 'out': 2},
              {'in': 41, 'out': 42},
            ]
          },
          'bad': {
            'set': [
              {'in': 1, 'out': 999},
            ]
          },
          'err': {
            'set': [
              {'in': 0, 'err': 'zero refused'},
            ]
          },
          'ctx': {
            'set': [
              {
                'ctx': {'opname': 'create'},
                'match': {
                  'ctx': {
                    'op': {'name': 'create', 'input': 'data'}
                  }
                }
              },
            ]
          },
        }
      }
    };

dynamic _inc(dynamic n) {
  if (0 == n) {
    throw Exception('smoke: zero refused');
  }
  return n + 1;
}

Future<dynamic> _incAsync(dynamic n) async {
  await Future<void>.delayed(Duration.zero);
  return _inc(n);
}

Run _pack() {
  final runner = makeRunner(_makespec(), UnivecSDK.test());
  return runner('smoke');
}

// Run `body`, requiring it to raise an omni failure whose message contains
// `want`.
Future<void> _mustfail(Future<void> Function() body, String want) async {
  var raised = false;
  try {
    await body();
  } on OmniError catch (err) {
    raised = true;
    ok(err.toString().contains(want),
        'expected a failure containing "' + want + '", got: ' + err.toString());
  }
  ok(raised, 'expected the runner to FAIL, but it passed');
}

void tests() {
  describe('omni', () {

    test('runset passes a correct subject', (t) async {
      final run = _pack();
      await run.runset(run.spec['basic'], _inc);
      equal(2, run.caseCount, 'both smoke entries must be driven');
    });

    test('runset fails a wrong result', (t) async {
      final run = _pack();
      await _mustfail(
          () => run.runset(run.spec['bad'], _inc), 'result mismatch');
    });

    test('an expected error is matched, a missing one fails', (t) async {
      final run = _pack();
      await run.runset(run.spec['err'], _inc);

      final run2 = _pack();
      await _mustfail(() => run2.runset(run2.spec['err'], (dynamic n) => n),
          'expected error did not occur');
    });

    // The two-pass drive (omni.dart decision 1): the same verdicts must hold
    // when the subject answers a Future.
    test('an async subject passes, fails and errors alike', (t) async {
      final run = _pack();
      await run.runset(run.spec['basic'], _incAsync);
      equal(2, run.caseCount, 'both smoke entries must be driven');

      final run2 = _pack();
      await _mustfail(
          () => run2.runset(run2.spec['bad'], _incAsync), 'result mismatch');

      final run3 = _pack();
      await run3.runset(run3.spec['err'], _incAsync);
    });

    // A ctx entry must reach the subject as a real Context, and its post-run
    // state must be visible to `match: {ctx: ...}` (decision 3).
    test('a ctx entry is materialised and read back', (t) async {
      final run = _pack();
      await run.runset(run.spec['ctx'], (dynamic ctx) {
        ok(null != ctx.op, 'ctx must arrive as a real Context');
        return null;
      });
      equal(1, run.caseCount);
    });

    test('a subject that never runs is reported', (t) async {
      final run = _pack();
      await _mustfail(() => run.runset(run.spec['basic']), 'no test subject');
    });

  });
}
