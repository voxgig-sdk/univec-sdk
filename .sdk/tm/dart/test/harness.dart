// Minimal dependency-free test harness for the generated Univec SDK.
//
// Mirrors the shape of the donor (ts) node:test usage: describe/test blocks
// register cases which run sequentially (deterministic order), `t.skip()`
// marks a case skipped, and the assertion helpers throw AssertionFailure.
// The suite entry (test/main.dart) awaits runAll() and exits non-zero on
// any failure.

import 'dart:async';

class AssertionFailure implements Exception {
  final String message;
  AssertionFailure(this.message);
  @override
  String toString() => 'AssertionFailure: ' + message;
}

class T {
  bool skipped = false;
  String? reason;
  void skip([String? r]) {
    skipped = true;
    reason = r;
  }
}

typedef TestBody = dynamic Function(T t);

class _Case {
  final String name;
  final TestBody body;
  _Case(this.name, this.body);
}

final List<_Case> _cases = [];
final List<String> _prefix = [];

void describe(String name, void Function() body) {
  _prefix.add(name);
  try {
    body();
  } finally {
    _prefix.removeLast();
  }
}

void test(String name, TestBody body) {
  _cases.add(_Case(([..._prefix, name]).join(' > '), body));
}

void fail(String msg) => throw AssertionFailure(msg);

void ok(dynamic cond, [String? msg]) {
  if (true != cond) {
    fail(msg ?? 'expected true, got ' + cond.toString());
  }
}

void equal(dynamic a, dynamic b, [String? msg]) {
  if (!_eq(a, b)) {
    fail((null == msg ? 'equal' : msg) +
        ': [' +
        a.toString() +
        '] != [' +
        b.toString() +
        ']');
  }
}

void deepEqual(dynamic a, dynamic b, [String? msg]) {
  if (!deq(a, b)) {
    fail((null == msg ? 'deepEqual' : msg) +
        ': [' +
        a.toString() +
        '] != [' +
        b.toString() +
        ']');
  }
}

bool _eq(dynamic a, dynamic b) {
  if (a is num && b is num) {
    return a == b;
  }
  return a == b;
}

// Deep structural equality over JSON-like values.
bool deq(dynamic a, dynamic b) {
  if (null == a && null == b) {
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (!deq(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) {
      return false;
    }
    for (final k in a.keys) {
      if (!b.containsKey(k) || !deq(a[k], b[k])) {
        return false;
      }
    }
    return true;
  }
  return _eq(a, b);
}

Future<int> runAll() async {
  var pass = 0;
  var failed = 0;
  var skip = 0;
  final failures = <String>[];

  for (final c in _cases) {
    final t = T();
    try {
      await Future.sync(() => c.body(t));
      if (t.skipped) {
        skip++;
        print('skip: ' + c.name + (null == t.reason ? '' : ' (' + t.reason! + ')'));
      } else {
        pass++;
      }
    } catch (e, st) {
      failed++;
      failures.add('FAIL: ' + c.name + '\n  ' + e.toString() + '\n' + st.toString());
    }
  }

  for (final f in failures) {
    print(f);
  }
  print('tests: ' +
      _cases.length.toString() +
      '  pass: ' +
      pass.toString() +
      '  fail: ' +
      failed.toString() +
      '  skip: ' +
      skip.toString());

  return failed;
}
