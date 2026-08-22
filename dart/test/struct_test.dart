// VERSION: @voxgig/struct 0.0.10 (dart port)
// Drives the scaffold's shared struct corpus (../.sdk/test/test.json,
// group "struct") through the vendored struct port, reached via the SDK's
// utility surface — mirroring ts test/utility/StructUtility.test.ts.

import 'harness.dart';
import 'runner.dart' show resolveTestFile;
import 'struct_corpus.dart' as corpus;

import '../lib/UnivecSDK.dart';

const TEST_JSON_FILE = '../.sdk/test/test.json';

void tests() {
  describe('struct', () {
    test('exists', (t) {
      final s = UnivecSDK.test().utility().struct;

      const fns = [
        'clone', 'delprop', 'escre', 'escurl', 'filter',
        'flatten', 'getelem', 'getprop',
        'getpath', 'haskey', 'inject', 'isempty', 'isfunc',
        'iskey', 'islist', 'ismap', 'isnode', 'items',
        'join', 'jsonify', 'keysof', 'merge', 'pad', 'pathify',
        'select', 'setpath', 'size', 'slice', 'setprop',
        'strkey', 'stringify', 'transform', 'typify', 'typename',
        'validate', 'walk',
      ];

      for (final fn in fns) {
        ok(null != s.byName(fn), fn + ' should be a function');
      }
    });

    test('corpus', (t) {
      final nfail = corpus.structCorpus(resolveTestFile(TEST_JSON_FILE));
      equal(0, nfail, 'struct corpus failures');
      ok(0 < corpus.structCorpusPassCount(), 'struct corpus must actually run');
    });
  });
}
