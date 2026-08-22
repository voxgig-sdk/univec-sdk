// VERSION: @voxgig/struct 0.0.10 (dart port)
// This test utility runs the JSON-specified tests in ../.sdk/test/test.json
// (the scaffold corpus of a @voxgig/sdkgen project).
//
// Port of the donor ts test/runner.ts. Dart has no dynamic property access,
// so subjects resolve through Utility.byName / StructUtility.byName, and
// class instances (Context, Spec, Result, ...) are normalised to maps via
// their toJSON() methods before matching.

import 'dart:convert';
import 'dart:io';

import '../lib/utility/voxgig_struct.dart' as vs;
import '../lib/utility/ErrUtility.dart';

import 'harness.dart' show AssertionFailure, deq, fail;

const NULLMARK = '__NULL__'; // Value is JSON null
const UNDEFMARK = '__UNDEF__'; // Value is not present (thus, undefined).
const EXISTSMARK = '__EXISTS__'; // Value exists (not undefined).

// Resolve the corpus path against the CWD (package root) or the test dir.
String resolveTestFile(String testfile) {
  if (File(testfile).existsSync()) {
    return testfile;
  }
  try {
    final scriptDir = File(Platform.script.toFilePath()).parent.path;
    final alt = scriptDir + '/' + testfile;
    if (File(alt).existsSync()) {
      return alt;
    }
    final alt2 = scriptDir + '/../' + testfile;
    if (File(alt2).existsSync()) {
      return alt2;
    }
  } catch (_e) {
    // Fall through to the raw path.
  }
  return testfile;
}

class RunPack {
  dynamic spec;
  dynamic client;
  dynamic subject;
  late Future<void> Function(dynamic testspec, dynamic testsubject) runset;
  late Future<void> Function(
          dynamic testspec, Map<String, bool> flags, dynamic testsubject)
      runsetflags;
}

Future<Future<RunPack> Function(String name, [dynamic store])> makeRunner(
    String testfile, dynamic client) async {
  return (String name, [dynamic store]) async {
    store ??= {};

    final utility = client.utility();

    final spec = resolveSpec(name, testfile);
    final clients = await resolveClients(client, spec, store);
    dynamic subject = resolveSubject(name, utility);

    Future<void> runsetflags(
        dynamic testspec, Map<String, bool> flags, dynamic testsubject) async {
      subject = testsubject ?? subject;
      final rflags = resolveFlags(flags);
      final testspecmap = fixJson(testspec, rflags);

      final testset = vs.getprop(testspecmap, 'set') ?? [];
      for (var entry in (testset as List)) {
        try {
          entry = resolveEntry(entry, rflags);

          final testpack =
              resolveTestPack(name, entry, subject, client, clients);
          final args = resolveArgs(entry, testpack, utility);

          dynamic res =
              await Future.value(Function.apply(testpack['subject'], args));
          res = fixJson(res, rflags);
          entry['res'] = res;

          checkResult(entry, args, res);
        } on AssertionFailure {
          rethrow;
        } catch (err) {
          handleError(entry, err);
        }
      }
    }

    Future<void> runset(dynamic testspec, dynamic testsubject) =>
        runsetflags(testspec, {}, testsubject);

    final runpack = RunPack();
    runpack.spec = spec;
    runpack.client = client;
    runpack.subject = subject;
    runpack.runset = runset;
    runpack.runsetflags = runsetflags;

    return runpack;
  };
}

dynamic resolveSpec(String name, String testfile) {
  final alltests =
      jsonDecode(File(resolveTestFile(testfile)).readAsStringSync());

  return vs.getprop(vs.getprop(alltests, 'primary'), name) ??
      vs.getprop(alltests, name) ??
      alltests;
}

Future<Map<String, dynamic>> resolveClients(
    dynamic client, dynamic spec, dynamic store) async {
  final clients = <String, dynamic>{};
  final cdefs = vs.getpath(spec, 'DEF.client');
  if (cdefs is Map) {
    for (final cn in vs.keysof(cdefs)) {
      final cdef = cdefs[cn];
      final copts = vs.getpath(cdef, 'test.options') ?? {};
      if (store is Map) {
        vs.inject(copts, store);
      }
      clients[cn] = await Future.value(client.tester(copts));
    }
  }
  return clients;
}

dynamic resolveSubject(String name, dynamic container) {
  return container.byName(name) ?? container.struct.byName(name);
}

Map<String, bool> resolveFlags(Map<String, bool>? flags) {
  flags ??= {};
  flags['null'] = null == flags['null'] ? true : true == flags['null'];
  return flags;
}

dynamic resolveEntry(dynamic entry, Map<String, bool> flags) {
  if (null == entry['out'] && true == flags['null']) {
    entry['out'] = NULLMARK;
  }
  return entry;
}

void checkResult(dynamic entry, List<dynamic> args, dynamic res) {
  var matched = false;

  if (null != entry['err']) {
    fail('Expected error did not occur: ' +
        entry['err'].toString() +
        '\n\nENTRY: ' +
        safeStringify(entry));
  }

  if (null != entry['match']) {
    match(entry['match'], {
      'in': entry['in'],
      'args': args,
      'out': entry['res'],
      'ctx': entry['ctx'],
    });
    matched = true;
  }

  final out = entry['out'];

  if (deq(res, out)) {
    return;
  }

  // NOTE: allow match with no out.
  if (matched && (NULLMARK == out || null == out)) {
    return;
  }

  fail('RESULT: [' +
      safeStringify(res) +
      '] != [' +
      safeStringify(out) +
      ']\n\nENTRY: ' +
      safeStringify(entry));
}

// Handle errors from test execution.
void handleError(dynamic entry, dynamic err) {
  entry['thrown'] = err.toString();

  final entryErr = entry['err'];

  if (null != entryErr) {
    if (true == entryErr || matchval(entryErr, errmsg(err))) {
      if (null != entry['match']) {
        match(entry['match'], {
          'in': entry['in'],
          'out': entry['res'],
          'ctx': entry['ctx'],
          'err': fixJson(err, {'null': true}),
        });
      }
      return;
    }

    fail('ERROR MATCH: [' +
        vs.stringify(entryErr) +
        '] <=> [' +
        errmsg(err) +
        ']');
  } else if (err is AssertionFailure) {
    throw err;
  } else {
    fail(err.toString() + '\n\nENTRY: ' + safeStringify(entry));
  }
}

List<dynamic> resolveArgs(dynamic entry, dynamic testpack, dynamic utility) {
  var args = <dynamic>[];

  if (null != entry['ctx']) {
    args = [entry['ctx']];
  } else if (null != entry['args']) {
    args = List<dynamic>.from(entry['args']);
  } else {
    args = [vs.clone(entry['in'])];
  }

  if (null != entry['ctx'] || null != entry['args']) {
    var first = args[0];
    if (vs.ismap(first)) {
      first = vs.clone(first);
      first = utility.makeContext(first);
      args[0] = first;
      entry['ctx'] = first;

      first.client = testpack['client'];
      first.utility = testpack['utility'];
    }
  }

  return args;
}

Map<String, dynamic> resolveTestPack(
    String name, dynamic entry, dynamic subject, dynamic client, dynamic clients) {
  final testpack = <String, dynamic>{
    'name': name,
    'client': client,
    'subject': subject,
    'utility': client.utility(),
  };

  if (null != entry['client']) {
    testpack['client'] = clients[entry['client']];
    testpack['utility'] = (testpack['client'] as dynamic).utility();
    testpack['subject'] = resolveSubject(name, testpack['utility']);
  }

  return testpack;
}

void match(dynamic check, dynamic basex) {
  final cbase = jsonNorm(basex, false);

  vs.walk(check, before: (key, val, parent, path) {
    if (!vs.isnode(val)) {
      final baseval = vs.getpath(cbase, path);

      if (deq(baseval, val)) {
        return val;
      }

      // Explicit undefined expected
      if (UNDEFMARK == val && null == baseval) {
        return val;
      }

      // Explicit defined expected
      if (EXISTSMARK == val && null != baseval) {
        return val;
      }

      if (!matchval(val, baseval)) {
        fail('MATCH: ' +
            (path as List).join('.') +
            ': [' +
            vs.stringify(val) +
            '] <=> [' +
            vs.stringify(baseval) +
            ']');
      }
    }

    return val;
  });
}

bool matchval(dynamic check, dynamic base) {
  var pass = deq(check, base);

  if (!pass) {
    if (check is String) {
      final basestr = vs.stringify(base);

      final rem = RegExp(r'^/(.+)/$').firstMatch(check);
      if (null != rem) {
        pass = RegExp(rem.group(1)!).hasMatch(basestr);
      } else {
        pass = basestr
            .toLowerCase()
            .contains(vs.stringify(check).toLowerCase());
      }
    } else if (check is Function) {
      pass = true;
    }
  }

  return pass;
}

String safeStringify(dynamic val) {
  try {
    return vs.jsonify(jsonNorm(val, false));
  } catch (_e) {
    return val.toString();
  }
}

dynamic fixJson(dynamic val, Map<String, bool> flags) =>
    jsonNorm(val, true == flags['null']);

// Normalise a value to a JSON-like structure: class instances are
// converted via toJSON(), error values become {name, code, message}
// records, functions are omitted (map members) or nulled, and (with
// nullflag) nulls become the NULLMARK sentinel.
dynamic jsonNorm(dynamic v, bool nullflag, [Set<dynamic>? seen]) {
  seen ??= <dynamic>{};

  if (null == v) {
    return nullflag ? NULLMARK : null;
  }
  if (v is num || v is bool || v is String) {
    return v;
  }
  if (v is Map) {
    if (seen.contains(v)) {
      return '[Circular]';
    }
    seen.add(v);
    final out = <String, dynamic>{};
    v.forEach((k, x) {
      if (x is! Function) {
        out[k.toString()] = jsonNorm(x, nullflag, seen);
      }
    });
    seen.remove(v);
    return out;
  }
  if (v is List) {
    if (seen.contains(v)) {
      return '[Circular]';
    }
    seen.add(v);
    final out = v.map((x) => jsonNorm(x, nullflag, seen)).toList();
    seen.remove(v);
    return out;
  }
  if (iserr(v)) {
    final out = <String, dynamic>{
      'name': v.runtimeType.toString(),
      'message': errmsg(v),
    };
    final code = errcode(v);
    if ('' != code) {
      out['code'] = code;
    }
    return out;
  }
  if (v is Function) {
    return nullflag ? NULLMARK : null;
  }
  if (seen.contains(v)) {
    return '[Circular]';
  }
  try {
    seen.add(v);
    final j = (v as dynamic).toJSON();
    final out = jsonNorm(j, nullflag, seen);
    seen.remove(v);
    return out;
  } catch (_e) {
    seen.remove(v);
    return v.toString();
  }
}

void nullModifier(dynamic val, dynamic key, dynamic parent) {
  if (NULLMARK == val) {
    vs.setprop(parent, key, null);
  } else if (val is String) {
    vs.setprop(parent, key, val.replaceAll(NULLMARK, 'null'));
  }
}
