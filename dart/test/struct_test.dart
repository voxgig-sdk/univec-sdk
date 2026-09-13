// VERSION: @voxgig/struct 0.0.10 (dart port)
// Drives the scaffold's shared struct corpus (../.sdk/test/test.json, root
// key "struct") through the vendored struct port, reached via the SDK's
// utility surface — mirroring ts test/utility/StructUtility.test.ts and the
// java target's StructCorpusTest.
//
// The engine is the VENDORED @voxgig/omni runner, driven through
// test/omni.dart. It supersedes test/struct_corpus.dart, the second,
// independent runner this suite used to carry (its own fixJson, eqv,
// matchval, doMatch and record/count loop — 531 lines that could and did
// drift from the shared semantics).
//
// Two behavioural changes come with the engine swap, both deliberate:
//
// - A failing entry now THROWS, with the section, the index and the entry
//   named, instead of being counted into a tally. The first failure in a
//   category stops that category's case; the other categories still run.
//
// - A missing or EMPTY section FAILS. The retired runner skipped one
//   silently: `sentinels.*` had not existed in the corpus for some time and
//   its six drive sites were running zero assertions while reporting PASS.
//   They are gone; the corpus's `nullsem` group takes their place below.

import 'harness.dart';
import 'omni.dart';

import '../lib/UnivecSDK.dart';
import '../lib/utility/voxgig_struct.dart' as s;

const TEST_JSON_FILE = '../.sdk/test/test.json';

Run? _runner;

Run _run() {
  if (null == _runner) {
    final make = makeRunner(TEST_JSON_FILE, UnivecSDK.test());
    final run = make('struct');
    ok(null != run.spec, 'struct section not found in ' + TEST_JSON_FILE);
    _runner = run;
  }
  return _runner!;
}

// A getter, not a field: every read must go through _run(), or the first
// section driven in a case reads a spec the lazy setup has not built yet.
dynamic get _spec => _run().spec;

// ---------------------------------------------------------------------------
// Drive helpers
// ---------------------------------------------------------------------------

dynamic _vget(dynamic vin, String key) =>
    (vin is Map && vin.containsKey(key)) ? vin[key] : null;

bool _vhas(dynamic vin, String key) => vin is Map && vin.containsKey(key);

// omni.dart hands a zero-argument entry the struct port's own no-value
// sentinel (test/omni.dart, decision 4). Only typify/stringify/pathify know
// what to do with it; every other section wants the port's single `null`,
// which is exactly what the retired runner passed.
dynamic _plain(dynamic val) => identical(val, s.pathifyNoArg) ? null : val;

// Drive one corpus section. A missing, non-set or EMPTY section fails here,
// before any subject runs: a renamed fixture must not report PASS over zero
// assertions.
Future<void> _sec(String cat, String name, bool nulls,
    dynamic Function(dynamic) subject,
    {bool noarg = false}) async {
  final catspec = s.getprop(_spec, cat);
  ok(null != catspec,
      'struct corpus category missing: ' + cat + ' - check .sdk/test/struct/');

  final secspec = s.getprop(catspec, name);
  ok(null != secspec,
      'struct corpus section missing: ' + cat + '.' + name +
          ' - check .sdk/test/struct/');

  final testset = s.getprop(secspec, 'set');
  ok(testset is List && testset.isNotEmpty,
      'struct corpus section is EMPTY: ' + cat + '.' + name +
          ' - zero cases would run');

  await _run().runsetflags(secspec, Flags(nulls: nulls, name: cat + '.' + name),
      (dynamic val) => subject(noarg ? val : _plain(val)));
}

// A section that is ONE case rather than a set (merge.basic, inject.basic,
// transform.basic): wrapped into a one-entry set so the same engine, the
// same normalisation and the same failure text apply.
Future<void> _one(String cat, String name,
    dynamic Function(dynamic) subject) async {
  final catspec = s.getprop(_spec, cat);
  ok(null != catspec,
      'struct corpus category missing: ' + cat + ' - check .sdk/test/struct/');

  final node = s.getprop(catspec, name);
  ok(node is Map && node.containsKey('in'),
      'struct corpus single-case section missing: ' + cat + '.' + name);

  await _run().runsetflags({
    'set': [node]
  }, Flags(name: cat + '.' + name), (dynamic val) => subject(_plain(val)));
}

// ---------------------------------------------------------------------------
// Subjects that need more than one expression
// ---------------------------------------------------------------------------

dynamic _walkCopySubject(dynamic vin) {
  var cur = <dynamic>[null];
  walkcopy(key, v, parent, path) {
    if (key == null) {
      cur[0] = [
        s.ismap(v) ? <String, dynamic>{} : (s.islist(v) ? <dynamic>[] : v)
      ];
      return v;
    }
    var i = s.size(path);
    dynamic nv;
    if (s.isnode(v)) {
      var c = cur[0] as List;
      while (c.length <= i) {
        c.add(null);
      }
      nv = s.ismap(v) ? <String, dynamic>{} : <dynamic>[];
      c[i] = nv;
    } else {
      nv = v;
    }
    s.setprop(s.getelem(cur[0], i - 1), key, nv);
    return v;
  }

  s.walk(vin, before: walkcopy);
  return s.getelem(cur[0], 0);
}

dynamic _walkDepthSubject(dynamic vin) {
  var state = <String, dynamic>{'top': null, 'cur': null};
  copy(key, v, parent, path) {
    if (key == null || s.isnode(v)) {
      var child = s.islist(v) ? <dynamic>[] : <String, dynamic>{};
      if (key == null) {
        state['top'] = child;
        state['cur'] = child;
      } else {
        s.setprop(state['cur'], key, child);
        state['cur'] = child;
      }
    } else {
      s.setprop(state['cur'], key, v);
    }
    return v;
  }

  s.walk(_vget(vin, 'src'), before: copy, maxdepth: _vget(vin, 'maxdepth'));
  return state['top'];
}

dynamic _walkLogSubject(dynamic vin) {
  var log = <dynamic>[];
  walklog(key, v, parent, path) {
    s.setprop(
        log,
        s.size(log),
        'k=' +
            (key == null ? s.stringify() : s.stringify(key)) +
            ', v=' +
            s.stringify(v) +
            ', p=' +
            (parent == null ? s.stringify() : s.stringify(parent)) +
            ', t=' +
            s.pathify(path));
    return v;
  }

  s.walk(vin, after: walklog);
  return log;
}

// ---------------------------------------------------------------------------
// The suite
// ---------------------------------------------------------------------------

void tests() {
  describe('struct', () {

    test('exists', (t) {
      final u = UnivecSDK.test().utility().struct;

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
        ok(null != u.byName(fn), fn + ' should be a function');
      }
    });

    test('minor', (t) async {
      await _sec('minor', 'isnode', true, (v) => s.isnode(v));
      await _sec('minor', 'ismap', true, (v) => s.ismap(v));
      await _sec('minor', 'islist', true, (v) => s.islist(v));
      await _sec('minor', 'iskey', false, (v) => s.iskey(v));
      await _sec('minor', 'strkey', false, (v) => s.strkey(v));
      await _sec('minor', 'isempty', false, (v) => s.isempty(v));
      await _sec('minor', 'isfunc', true, (v) => s.isfunc(v));
      await _sec('minor', 'clone', false, (v) => s.clone(v));
      await _sec('minor', 'escre', true, (v) => s.escre(v));
      await _sec('minor', 'escurl', true, (v) => s.escurl(v));

      await _sec('minor', 'stringify', false, (vin) => _vhas(vin, 'val')
          ? s.stringify(_vget(vin, 'val'), _vget(vin, 'max'))
          : s.stringify());

      await _sec('minor', 'jsonify', false,
          (vin) => s.jsonify(_vget(vin, 'val'), _vget(vin, 'flags')));

      await _sec('minor', 'getelem', false, (vin) {
        var alt = _vget(vin, 'alt');
        return alt == null
            ? s.getelem(_vget(vin, 'val'), _vget(vin, 'key'))
            : s.getelem(_vget(vin, 'val'), _vget(vin, 'key'), alt);
      });

      await _sec('minor', 'delprop', true,
          (vin) => s.delprop(_vget(vin, 'parent'), _vget(vin, 'key')));

      await _sec('minor', 'size', false, (v) => s.size(v));

      await _sec('minor', 'slice', false,
          (vin) => s.slice(_vget(vin, 'val'), _vget(vin, 'start'),
              _vget(vin, 'end')));

      await _sec('minor', 'pad', false,
          (vin) => s.pad(_vget(vin, 'val'), _vget(vin, 'pad'),
              _vget(vin, 'char')));

      await _sec('minor', 'pathify', false, (vin) => _vhas(vin, 'path')
          ? s.pathify(_vget(vin, 'path'), _vget(vin, 'from'))
          : s.pathify(s.pathifyNoArg, _vget(vin, 'from')));

      await _sec('minor', 'items', true, (v) => s.items(v));

      await _sec('minor', 'getprop', false, (vin) {
        var alt = _vget(vin, 'alt');
        return alt == null
            ? s.getprop(_vget(vin, 'val'), _vget(vin, 'key'))
            : s.getprop(_vget(vin, 'val'), _vget(vin, 'key'), alt);
      });

      await _sec('minor', 'setprop', true,
          (vin) => s.setprop(_vget(vin, 'parent'), _vget(vin, 'key'),
              _vget(vin, 'val')));

      await _sec('minor', 'haskey', false,
          (vin) => s.haskey(_vget(vin, 'src'), _vget(vin, 'key')));

      await _sec('minor', 'keysof', true, (v) => s.keysof(v));

      await _sec('minor', 'join', false,
          (vin) => s.join(_vget(vin, 'val'), _vget(vin, 'sep'),
              _vget(vin, 'url')));

      // The one section that must see a zero-argument entry AS one: the
      // corpus distinguishes `typify()` (T_noval) from `typify(null)`
      // (T_null), so the port's no-value sentinel goes through unmapped.
      await _sec('minor', 'typify', false, (v) => s.typify(v), noarg: true);

      await _sec('minor', 'setpath', false,
          (vin) => s.setpath(_vget(vin, 'store'), _vget(vin, 'path'),
              _vget(vin, 'val')));

      await _sec('minor', 'filter', true, (vin) {
        bool Function(List<dynamic>) check;
        var c = _vget(vin, 'check');
        if (c == 'gt3') {
          check = (n) => n[1] is num && n[1] > 3;
        } else if (c == 'lt3') {
          check = (n) => n[1] is num && n[1] < 3;
        } else {
          check = (n) => false;
        }
        return s.filter(_vget(vin, 'val'), check);
      });

      await _sec('minor', 'typename', true,
          (v) => s.typename(v is num ? v.toInt() : 0));

      await _sec('minor', 'flatten', true, (vin) {
        var d = _vget(vin, 'depth');
        return s.flatten(_vget(vin, 'val'), d is num ? d.toInt() : 1);
      });
    });

    test('walk', (t) async {
      // walk.log is one case whose `out` carries three logs; the corpus has
      // always been driven on the `after` walk alone (before/both remain an
      // open coverage gap, as they were under the retired runner).
      final walks = s.getprop(_spec, 'walk');
      ok(null != walks, 'struct corpus category missing: walk');
      final log = s.getprop(walks, 'log');
      ok(null != s.getpath(log, ['out', 'after']),
          'struct corpus section missing: walk.log.out.after');
      await _run().runsetflags({
        'set': [
          {'in': s.getprop(log, 'in'), 'out': s.getpath(log, ['out', 'after'])}
        ]
      }, Flags(name: 'walk.log'), (dynamic vin) => _walkLogSubject(vin));

      await _sec('walk', 'basic', true, (vin) => s.walk(vin,
          after: (k, v, p, path) {
            if (v is String) {
              return v + '~' + (path as List).map((e) => s.jsString(e)).join('.');
            }
            return v;
          }));

      await _sec('walk', 'copy', true, _walkCopySubject);
      await _sec('walk', 'depth', false, _walkDepthSubject);
    });

    test('merge', (t) async {
      await _one('merge', 'basic', (vin) => s.merge(s.clone(vin)));
      await _sec('merge', 'cases', true, (v) => s.merge(v));
      await _sec('merge', 'array', true, (v) => s.merge(v));
      await _sec('merge', 'integrity', true, (v) => s.merge(v));
      await _sec('merge', 'depth', true,
          (vin) => s.merge(_vget(vin, 'val'), _vget(vin, 'depth')));
    });

    test('getpath', (t) async {
      await _sec('getpath', 'basic', true,
          (vin) => s.getpath(_vget(vin, 'store'), _vget(vin, 'path')));

      await _sec('getpath', 'relative', true, (vin) {
        var dp = _vget(vin, 'dpath');
        var dpath = dp is String ? dp.split('.') : null;
        var injdef = {'dparent': _vget(vin, 'dparent'), 'dpath': dpath};
        return s.getpath(_vget(vin, 'store'), _vget(vin, 'path'), injdef);
      });

      await _sec('getpath', 'special', true,
          (vin) => s.getpath(_vget(vin, 'store'), _vget(vin, 'path'),
              _vget(vin, 'inj')));

      await _sec('getpath', 'handler', true, (vin) {
        var store = {'\$TOP': _vget(vin, 'store'), '\$FOO': () => 'foo'};
        handler(inj, val, ref, st) => s.isfunc(val) ? val() : val;
        return s.getpath(store, _vget(vin, 'path'), {'handler': handler});
      });
    });

    test('inject', (t) async {
      await _one(
          'inject',
          'basic',
          (vin) => s.inject(s.clone(s.getprop(vin, 'val')),
              s.clone(s.getprop(vin, 'store'))));

      await _sec('inject', 'string', true,
          (vin) => s.inject(_vget(vin, 'val'), _vget(vin, 'store'),
              {'modify': nullModifier, 'extra': _vget(vin, 'current')}));

      await _sec('inject', 'deep', true,
          (vin) => s.inject(_vget(vin, 'val'), _vget(vin, 'store')));
    });

    test('transform', (t) async {
      await _one('transform', 'basic',
          (vin) => s.transform(s.getprop(vin, 'data'), s.getprop(vin, 'spec')));

      for (var gn in ['paths', 'cmds', 'each', 'pack', 'ref']) {
        await _sec('transform', gn, true,
            (vin) => s.transform(_vget(vin, 'data'), _vget(vin, 'spec')));
      }

      await _sec('transform', 'modify', true, (vin) {
        modifier(v, key, parent, inj) {
          if (v is String && key != null && parent != null) {
            s.setprop(parent, key, '@' + v);
          }
        }

        return s.transform(_vget(vin, 'data'), _vget(vin, 'spec'),
            {'modify': modifier, 'extra': _vget(vin, 'store')});
      });

      await _sec('transform', 'format', false,
          (vin) => s.transform(_vget(vin, 'data'), _vget(vin, 'spec')));

      await _sec('transform', 'apply', true,
          (vin) => s.transform(_vget(vin, 'data'), _vget(vin, 'spec')));
    });

    test('validate', (t) async {
      await _sec('validate', 'basic', false,
          (vin) => s.validate(_vget(vin, 'data'), _vget(vin, 'spec')));

      for (var gn in ['child', 'one', 'exact']) {
        await _sec('validate', gn, true,
            (vin) => s.validate(_vget(vin, 'data'), _vget(vin, 'spec')));
      }

      await _sec('validate', 'invalid', false,
          (vin) => s.validate(_vget(vin, 'data'), _vget(vin, 'spec')));

      await _sec('validate', 'special', true,
          (vin) => s.validate(_vget(vin, 'data'), _vget(vin, 'spec'),
              _vget(vin, 'inj')));
    });

    test('select', (t) async {
      for (var gn in ['basic', 'operators', 'edge', 'alts']) {
        await _sec('select', gn, true,
            (vin) => s.select(_vget(vin, 'obj'), _vget(vin, 'query')));
      }
    });

    // Does a PRESENT key holding a JSON null read as "no value"? Opt-in per
    // project: create-sdkgen ships the section, an older project corpus may
    // predate it — say so OUT LOUD as a skip rather than passing vacuously.
    // Every lane runs {null: false}: without the flag the runner rewrites
    // every null to '__NULL__' and the section asserts nothing about null.
    test('nullsem', (t) async {
      final nullsem = s.getprop(_spec, 'nullsem');
      if (null == nullsem) {
        t.skip('corpus predates struct.nullsem - refresh .sdk/test/struct '
            'from create-sdkgen');
        return;
      }

      await _sec('nullsem', 'getprop', false, (vin) => _vhas(vin, 'alt')
          ? s.getprop(_vget(vin, 'val'), _vget(vin, 'key'), _vget(vin, 'alt'))
          : s.getprop(_vget(vin, 'val'), _vget(vin, 'key')));

      await _sec('nullsem', 'getelem', false, (vin) => _vhas(vin, 'alt')
          ? s.getelem(_vget(vin, 'val'), _vget(vin, 'key'), _vget(vin, 'alt'))
          : s.getelem(_vget(vin, 'val'), _vget(vin, 'key')));

      await _sec('nullsem', 'getpath', false,
          (vin) => s.getpath(_vget(vin, 'store'), _vget(vin, 'path')));

      await _sec('nullsem', 'haskey', false,
          (vin) => s.haskey(_vget(vin, 'src'), _vget(vin, 'key')));

      await _sec('nullsem', 'keysof', false, (v) => s.keysof(v));
    });

    // The vacuity guard the retired runner spelled as `0 < passCount`: a
    // suite that stopped executing the corpus would otherwise stay green.
    test('corpus-cases', (t) {
      final cases = _run().caseCount;
      print('struct corpus: cases ' + cases.toString());
      ok(1000 < cases,
          'struct corpus drove only ' + cases.toString() +
              ' cases - the corpus stopped running');
    });

  });
}
