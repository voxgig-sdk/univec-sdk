// Shared utility functions for unit tests.
//
// Provides the sdk-test-control.json loader (per-SDK skip control), the
// env-override helper for live-mode configuration, and test data path
// resolution. Port of the donor ts test/utility.ts.

import 'dart:convert';
import 'dart:io';

import 'harness.dart' show T;

// Resolve a path relative to the package root (CWD) or the test dir.
String resolveTestPath(String rel) {
  if (File(rel).existsSync()) {
    return rel;
  }
  try {
    final scriptDir = File(Platform.script.toFilePath()).parent.path;
    final alt = scriptDir + '/../' + rel;
    if (File(alt).existsSync()) {
      return alt;
    }
    final alt2 = scriptDir + '/' + rel;
    if (File(alt2).existsSync()) {
      return alt2;
    }
  } catch (_e) {
    // Fall through to the raw path.
  }
  return rel;
}

// Overrides configuration values with environment variables if available.
Map<String, dynamic> envOverride(Map<String, dynamic> m) {
  final env = Platform.environment;

  if ('TRUE' == env['PROJECTENV_TEST_LIVE'] ||
      'TRUE' == env['PROJECTENV_TEST_OVERRIDE']) {
    for (final k in m.keys.toList()) {
      var envval = env[k];
      if (null != envval) {
        envval = envval.trim();
        m[k] = envval.startsWith('{') ? jsonDecode(envval) : envval;
      }
    }
  }

  m['PROJECTENV_TEST_EXPLAIN'] =
      env['PROJECTENV_TEST_EXPLAIN'] ?? m['PROJECTENV_TEST_EXPLAIN'];

  return m;
}

// Loads sdk-test-control.json (cached). Returns an empty-skip object if
// the file is missing or unparsable so tests never crash on a bad config.
Map<String, dynamic>? _testControlCache;

Map<String, dynamic> loadTestControl() {
  if (null != _testControlCache) {
    return _testControlCache!;
  }
  try {
    final path = resolveTestPath('test/sdk-test-control.json');
    _testControlCache = Map<String, dynamic>.from(
        jsonDecode(File(path).readAsStringSync()));
  } catch (_e) {
    _testControlCache = {
      'version': 1,
      'test': {
        'skip': {
          'live': {'direct': [], 'entityOp': []},
          'unit': {'direct': [], 'entityOp': []},
        }
      }
    };
  }
  return _testControlCache!;
}

// Returns the skip decision for a given test name from sdk-test-control.json.
// `kind` is 'direct' (matches by `test` field) or 'entityOp' (matches by
// `entity` + `op`). `mode` is 'live' or 'unit'.
Map<String, dynamic> isControlSkipped(String kind, String name, String mode) {
  final ctrl = loadTestControl();
  dynamic list = [];
  final t = ctrl['test'];
  if (t is Map) {
    final skip = t['skip'];
    if (skip is Map) {
      final m = skip[mode];
      if (m is Map) {
        list = m[kind] ?? [];
      }
    }
  }
  for (final e in (list as List)) {
    if (e is! Map) {
      continue;
    }
    if ('direct' == kind && e['test'] == name) {
      return {'skip': true, 'reason': e['reason']};
    }
    if ('entityOp' == kind) {
      final key = (e['entity'] ?? '').toString() + '.' + (e['op'] ?? '').toString();
      if (key == name) {
        return {'skip': true, 'reason': e['reason']};
      }
    }
  }
  return {'skip': false};
}

// Skips the current test if sdk-test-control.json lists it. Returns true
// when skipped (caller should `return` immediately).
bool maybeSkipControl(T t, String kind, String name, bool live) {
  final decision = isControlSkipped(kind, name, live ? 'live' : 'unit');
  if (true == decision['skip']) {
    t.skip((decision['reason'] ?? 'skipped via sdk-test-control.json').toString());
    return true;
  }
  return false;
}

// Skips the current live test when required idmap keys aren't supplied.
// Generated tests call this when they would otherwise pass null values
// into a path/query param and 4xx the request.
bool skipIfMissingIds(T t, Map setup, List<String> requiredKeys) {
  if (true != setup['live']) {
    return false;
  }
  final idmap = setup['idmap'];
  final missing = requiredKeys
      .where((k) => !(idmap is Map) || null == idmap[k])
      .toList();
  if (missing.isNotEmpty) {
    t.skip('live test needs ' +
        missing.join(', ') +
        ' via *_ENTID env var (synthetic IDs only)');
    return true;
  }
  return false;
}

// Per-test live pacing delay (ms). Read from sdk-test-control.json
// `test.live.delayMs`; defaults to 500ms if absent or invalid.
int liveDelayMs() {
  final ctrl = loadTestControl();
  final t = ctrl['test'];
  final v = t is Map ? (t['live'] is Map ? t['live']['delayMs'] : null) : null;
  return (v is num && v >= 0) ? v.toInt() : 500;
}

// Live pacing helper. Generated tests await this after live calls; it
// sleeps liveDelayMs() only when the SDK's *_TEST_LIVE env var is set.
Future<void> liveDelay(String liveEnvVar) async {
  if ('TRUE' == Platform.environment[liveEnvVar]) {
    await Future.delayed(Duration(milliseconds: liveDelayMs()));
  }
}
