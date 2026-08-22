// Network-behaviour simulation over the offline mock transport. The `test`
// feature accepts an optional `net` config so unit tests can exercise slow,
// failing and offline conditions without a live server. These checks drive
// the transport through `direct()`, which needs no entity, so they run for
// every generated SDK regardless of its API shape. Port of ts test/netsim.test.ts.

import 'harness.dart';

import '../lib/UnivecSDK.dart';

void tests() {
  describe('netsim', () {
    test('offline simulation fails the request', (t) async {
      final sdk = UnivecSDK.test({
        'net': {'offline': true}
      });
      final res = await sdk.direct({'path': '/ping'});
      equal(false, res['ok'], 'offline network must fail the call');
    });

    test('failStatus simulation surfaces the error status', (t) async {
      final sdk = UnivecSDK.test({
        'net': {'failTimes': 1, 'failStatus': 503}
      });
      final res = await sdk.direct({'path': '/ping'});
      equal(false, res['ok']);
      equal(503, res['status'], 'simulated failure status is surfaced');
    });

    test('latency simulation delays the request', (t) async {
      const delay = 60;
      final sdk = UnivecSDK.test({
        'net': {'latency': delay}
      });
      final start = DateTime.now().millisecondsSinceEpoch;
      await sdk.direct({'path': '/ping'});
      final elapsed = DateTime.now().millisecondsSinceEpoch - start;
      // Generous lower bound to stay robust on slow CI.
      ok(elapsed >= delay - 25,
          'expected >= ' + (delay - 25).toString() + 'ms latency, got ' + elapsed.toString() + 'ms');
    });

    test('a plain test SDK still works with no net simulation', (t) async {
      final sdk = UnivecSDK.test();
      equal(true, null != sdk);
    });
  });
}
