import 'dart:convert';
import 'dart:math';

import '../UnivecError.dart';

// Everything that leaves the pipeline passes through clean; inside it data
// stays raw, so a hook can still read the header it must add to. See the
// generator's docs/explanation/secret-redaction.md.

const MAXDEPTH = 32;
const CIRCULAR = '[circular]';

// The `clean` block of the option spec (main.kit.optspec.clean in the sdkgen
// base model), held here because this pack's targets read no generated
// Schema module. Numbers are strings, like every optspec value.
const Map<String, dynamic> CLEAN_OPTSPEC = {
  'active': true,
  'keys':
      'key,secret,token,password,passwd,authorization,cookie,credential,signature',
  'values': '',
  'mask': '[redacted]',
  'hint': '0',
  'min': '4',
};

class _Drop {
  const _Drop();
}

const _drop = _Drop();

String _normkey(dynamic key) =>
    key.toString().toLowerCase().replaceAll(RegExp(r'[-_]'), '');

List<String> _splitkeys(dynamic keys) => (null == keys ? '' : keys.toString())
    .split(RegExp(r'\s*,\s*'))
    .map(_normkey)
    .where((k) => '' != k)
    .toList();

List<String> splitvalues(dynamic values) {
  if (values is List) {
    return values.whereType<String>().toList();
  }
  return (null == values ? '' : values.toString())
      .split(RegExp(r'\s*,\s*'))
      .where((v) => '' != v)
      .toList();
}

int _count(dynamic val, int dflt) {
  final n = val is num ? val : num.tryParse(val.toString());
  if (null == n || !n.isFinite || n < 0) {
    return dflt;
  }
  return n.floor();
}

Map<String, dynamic> makeCleanConfig(dynamic cleanopts) {
  final opts = cleanopts is Map ? cleanopts : {};
  return {
    'active': false != opts['active'],
    'keys': _splitkeys(opts['keys']),
    'values': <String>[],
    'mask': opts['mask'] is String ? opts['mask'] : '[redacted]',
    'hint': _count(opts['hint'], 0),
    'min': max(1, _count(opts['min'], 4)),
  };
}

dynamic _optionsOf(dynamic ctx) {
  if (ctx is Map) {
    return ctx['options'];
  }
  try {
    return ctx.options;
  } catch (_e) {
    return null;
  }
}

// A context without options (makeError accepts a bare one) still masks by
// the schema defaults.
Map _cleanConfig(dynamic ctx) {
  final options = _optionsOf(ctx);
  final derived = options is Map ? options['__derived__'] : null;
  final cfg = derived is Map ? derived['clean'] : null;
  if (cfg is Map) {
    return cfg;
  }
  return makeCleanConfig(CLEAN_OPTSPEC);
}

// The encoded forms a value travels in.
List<String> _forms(String value) {
  final out = <String>[value];
  void add(String s) {
    if ('' != s && !out.contains(s)) {
      out.add(s);
    }
  }

  try {
    add(base64Encode(utf8.encode(value)));
  } catch (_e) {}
  try {
    add(Uri.encodeComponent(value));
  } catch (_e) {}
  try {
    final j = jsonEncode(value);
    add(j.substring(1, j.length - 1));
  } catch (_e) {}
  return out;
}

void cleanAdd(dynamic ctx, dynamic value) {
  final cfg = _cleanConfig(ctx);
  final int min = cfg['min'];
  if (value is! String || value.length < min) {
    return;
  }
  final List values = cfg['values'];
  var changed = false;
  for (final form in _forms(value)) {
    if (form.length >= min && !values.contains(form)) {
      values.add(form);
      changed = true;
    }
  }
  if (changed) {
    values.sort((a, b) => b.toString().length - a.toString().length);
  }
}

// The hint is compared as a difference: 2 * hint overflows for a large one.
String _maskValue(Map cfg, String value) {
  final int hint = cfg['hint'];
  if (0 < hint && value.length - hint > hint) {
    return cfg['mask'] + value.substring(value.length - hint);
  }
  return cfg['mask'];
}

String _cleanString(Map cfg, String text) {
  var out = text;
  for (final value in cfg['values']) {
    if (out.contains(value)) {
      out = out.split(value).join(_maskValue(cfg, value));
    }
  }
  return out;
}

bool _sensitiveKey(Map cfg, dynamic key) {
  if (null == key || key is num) {
    return false;
  }
  final nk = _normkey(key);
  for (final k in cfg['keys']) {
    if (nk.contains(k)) {
      return true;
    }
  }
  return false;
}

// The value's own serialisation, when it has one: toJSON is the SDK's
// convention, toJson dart:convert's.
dynamic _json(dynamic val) {
  try {
    return val.toJSON();
  } on NoSuchMethodError {
    // No toJSON.
  }
  try {
    return val.toJson();
  } on NoSuchMethodError {
    return _drop;
  }
}

// A masked plain-data copy: toJSON honoured, functions dropped, cycles cut,
// and nothing shared with the live value, whose spec must stay raw.
dynamic _snapshot(Map cfg, dynamic val, dynamic key, int depth, List seen) {
  if (null == val) {
    return val;
  }

  if (val is String) {
    return _sensitiveKey(cfg, key) ? _maskValue(cfg, val) : _cleanString(cfg, val);
  }

  if (val is Function) {
    return _drop;
  }

  if (val is num || val is bool) {
    return _sensitiveKey(cfg, key) ? cfg['mask'] : val;
  }

  if (MAXDEPTH <= depth || seen.any((s) => identical(s, val))) {
    return CIRCULAR;
  }

  if (_sensitiveKey(cfg, key)) {
    return cfg['mask'];
  }

  seen.add(val);
  try {
    if (val is Iterable) {
      final out = <dynamic>[];
      var i = 0;
      for (final item in val) {
        final v = _snapshot(cfg, item, i, depth + 1, seen);
        out.add(identical(v, _drop) ? null : v);
        i++;
      }
      return out;
    }

    if (val is Map) {
      return _plain(cfg, val, depth, seen);
    }

    final json = _json(val);
    if (identical(json, _drop)) {
      if (val is Error || val is Exception) {
        return {'message': _cleanString(cfg, val.toString())};
      }
      return _cleanString(cfg, val.toString());
    }
    return identical(json, val)
        ? _cleanString(cfg, val.toString())
        : _snapshot(cfg, json, key, depth + 1, seen);
  } finally {
    seen.removeLast();
  }
}

Map<String, dynamic> _plain(Map cfg, Map val, int depth, List seen) {
  final out = <String, dynamic>{};
  for (final k in val.keys) {
    final v = _snapshot(cfg, val[k], k, depth + 1, seen);
    if (!identical(v, _drop)) {
      out[_cleanName(cfg, out, k.toString())] = v;
    }
  }
  return out;
}

// A registered value used as a property name is masked like any other
// string; names that mask alike take a counter, so none is lost.
String _cleanName(Map cfg, Map out, String key) {
  final name = _cleanString(cfg, key);
  if (name == key || !out.containsKey(name)) {
    return name;
  }
  var i = 1;
  while (out.containsKey(name + '#' + i.toString())) {
    i++;
  }
  return name + '#' + i.toString();
}

// The SDK's own error is cleaned in place, since it is about to be thrown.
dynamic clean(dynamic ctx, dynamic val) {
  final cfg = _cleanConfig(ctx);

  if (false == cfg['active']) {
    return val;
  }

  if (val is String) {
    return _cleanString(cfg, val);
  }

  if (val is UnivecError) {
    val.code = _cleanString(cfg, val.code);
    val.message = _cleanString(cfg, val.message);
    if (null != val.result) {
      val.result = _snapshot(cfg, val.result, 'result', 1, []);
    }
    if (null != val.spec) {
      val.spec = _snapshot(cfg, val.spec, 'spec', 1, []);
    }
    return val;
  }

  final out = _snapshot(cfg, val, null, 0, []);
  return identical(out, _drop) ? null : out;
}

bool cleanKey(dynamic ctx, dynamic key) => _sensitiveKey(_cleanConfig(ctx), key);

// Every scalar under a sensitive name, at any depth and of any shape: a
// credential mistyped as a map or a number is still a credential, and the
// validation error that rejects it quotes it.
void cleanAddSensitive(dynamic ctx, dynamic val,
    [bool under = false, int depth = 0, List? seen]) {
  if (null == val || MAXDEPTH <= depth) {
    return;
  }
  if (val is String) {
    if (under) {
      cleanAdd(ctx, val);
    }
    return;
  }
  if (val is num) {
    if (under) {
      cleanAdd(ctx, _numText(val));
    }
    return;
  }
  if (val is! Map && val is! List) {
    return;
  }
  final visited = seen ?? [];
  if (visited.any((s) => identical(s, val))) {
    return;
  }
  visited.add(val);
  if (val is Map) {
    for (final k in val.keys) {
      cleanAddSensitive(ctx, val[k], under || cleanKey(ctx, k), depth + 1, visited);
    }
  } else {
    for (final item in val as List) {
      cleanAddSensitive(ctx, item, under, depth + 1, visited);
    }
  }
}

// The decimal text JSON and ts give a number: 12345678.0 is "12345678".
String _numText(num n) =>
    (n is double && n.isFinite && n == n.truncateToDouble())
        ? n.toInt().toString()
        : n.toString();
