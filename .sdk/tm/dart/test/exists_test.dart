import 'harness.dart';

import '../lib/UnivecSDK.dart';

void tests() {
  describe('exists', () {
    test('test-mode', (t) async {
      final testsdk = UnivecSDK.test();
      equal(true, null != testsdk);
    });
  });
}
