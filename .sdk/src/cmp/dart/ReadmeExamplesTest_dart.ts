
import { cmp, Content, File } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'


// Emits dart/test/readme_examples_test.dart — a COMPLETENESS + PRESENCE gate
// over every ```dart fenced block in the three documents that ship dart
// examples:
//   - the repository ROOT README.md (one directory above the dart/ package),
//   - the per-language dart/README.md,
//   - the per-language dart/REFERENCE.md.
//
// Unlike the interpreted-language gates (py/rb), which EXECUTE every runnable
// block in a subprocess, and the go gate, which COMPILES every block, this
// gate is a dependency-free STRUCTURAL gate that runs inside the dependency-
// free dart test harness (no `dart analyze`/`dart run` subprocess, so it never
// depends on a resolvable package_config at test time). Per document it:
//   1. extracts every ```dart fenced block (tagged by source doc + index);
//   2. classifies each block into exactly one of
//      {runnable, illustration, compiled-nonrunnable} and asserts the
//      partition is complete (total == runnable + illustration + compiled);
//   3. asserts PRESENCE: every available doc carries at least one dart block,
//      and at least one RUNNABLE block (one that constructs the SDK or drives
//      a `client`), so no doc silently ships zero exercised dart examples.
//
// A missing doc is SKIPPED (not failed) — the root README is optional in a
// single-language checkout. The dart source is written with the fence marker
// and newline built from escapes (` = backtick) so this template literal
// stays clean.
const ReadmeExamplesTest = cmp(function ReadmeExamplesTest(props: any) {
  const { target, ctx$: { model } } = props

  const Name = model.const.Name
  const sdkClass = Name + 'SDK'

  // The API's capitalised semantic entities — used to detect entity-factory
  // references (client.<Entity>() ) inside a block.
  const entities = Object.values(getModelPath(model, `main.${KIT}.entity`) || {})
    .filter((e: any) => e && e.active !== false)
    .map((e: any) => nom(e, 'Name'))
  const entitiesLiteral = 0 === entities.length
    ? '<String>[]'
    : "<String>['" + entities.join("', '") + "']"

  File({ name: 'readme_examples_test.' + target.ext }, () => {
    Content(`// ${Name} SDK — documentation dart-examples presence & completeness gate.
// GENERATED — do not edit.
//
// A structural completeness gate over every dart fenced code block in three
// documents:
//   - the repository ROOT README.md (one directory above the dart/ package),
//   - the per-language dart/README.md,
//   - the per-language dart/REFERENCE.md.
//
// For each available document it partitions every block into exactly one of
// {runnable, illustration, compiled-nonrunnable}, asserts the partition adds
// up, and asserts the doc carries at least one runnable dart example. A
// missing document is skipped, not failed.

import 'dart:io';

import 'harness.dart';
import 'utility.dart';

// The triple-backtick markdown code fence (\\u0060 == backtick) and newline,
// built from escapes so the generator template literal stays clean.
const String _fence = '\\u0060\\u0060\\u0060';
const String _nl = '\\n';

const String _sdkClass = '${sdkClass}';

// The API's capitalised semantic entities, used to spot a client.<Entity>()
// factory call inside a block.
const List<String> _entities = ${entitiesLiteral};

// The three documents held to the gate, tagged by human label and path
// (relative to the package root, which is the CWD for 'dart run test/...').
final List<List<String>> _docs = [
  ['root README', '../README.md'],
  ['dart README.md', 'README.md'],
  ['dart REFERENCE.md', 'REFERENCE.md'],
];

// Split the doc on the code fence: odd-indexed segments are the inside of a
// fenced block (an info string on the first line, then the code). Only fences
// whose info string is exactly 'dart' are returned, so signature/markdown
// tables and other-language fences are skipped.
List<String> _blocksIn(String text) {
  final parts = text.split(_fence);
  final blocks = <String>[];
  for (var i = 1; i < parts.length; i += 2) {
    final seg = parts[i];
    final lines = seg.split(_nl);
    final info = lines[0].trim();
    if ('dart' == info) {
      blocks.add(lines.sublist(1).join(_nl));
    }
  }
  return blocks;
}

// A block is RUNNABLE — and therefore MUST be exercised — when it constructs
// the SDK (mentions the class) or drives a client the narrative built.
bool _isRunnable(String block) {
  if (block.contains(_sdkClass)) {
    return true;
  }
  if (block.contains('client.')) {
    return true;
  }
  for (final ent in _entities) {
    if (block.contains('.' + ent + '(')) {
      return true;
    }
  }
  return false;
}

// A NARROW illustration: a non-runnable block whose every non-blank line is a
// comment or an import — a pure signature/structure snippet with nothing to
// run. Anything with real statements falls to the compiled-nonrunnable bucket.
bool _isIllustration(String block) {
  if (_isRunnable(block)) {
    return false;
  }
  var sawLine = false;
  for (final raw in block.split(_nl)) {
    final line = raw.trim();
    if ('' == line) {
      continue;
    }
    sawLine = true;
    if (line.startsWith('//')) {
      continue;
    }
    if (line.startsWith('import ') || line.startsWith('export ')) {
      continue;
    }
    return false;
  }
  return sawLine;
}

String _classify(String block) {
  if (_isRunnable(block)) {
    return 'runnable';
  }
  if (_isIllustration(block)) {
    return 'illustration';
  }
  return 'compiled';
}

Map<String, int> _gate(String label, List<String> blocks) {
  var runnable = 0;
  var illustration = 0;
  var compiled = 0;
  for (final block in blocks) {
    final kind = _classify(block);
    if ('runnable' == kind) {
      runnable++;
    } else if ('illustration' == kind) {
      illustration++;
    } else {
      compiled++;
    }
  }
  final total = blocks.length;
  print(_nl +
      '[readme-examples] ' +
      label +
      ' dart blocks: total=' +
      total.toString() +
      ' runnable=' +
      runnable.toString() +
      ' compiled=' +
      compiled.toString() +
      ' illustration=' +
      illustration.toString());

  // Every block is accounted for by exactly one bucket.
  ok(total == runnable + illustration + compiled,
      label +
          ': dart-block accounting does not add up — total=' +
          total.toString() +
          ' but runnable+compiled+illustration=' +
          (runnable + illustration + compiled).toString());

  return {
    'total': total,
    'runnable': runnable,
    'compiled': compiled,
    'illustration': illustration,
  };
}

void tests() {
  describe('ReadmeExamples', () {
    for (final doc in _docs) {
      final label = doc[0];
      final rel = doc[1];

      test('dart-examples: ' + label, (t) async {
        final path = resolveTestPath(rel);
        if (!File(path).existsSync()) {
          t.skip(label + ' not found: ' + path);
          return;
        }

        final text = File(path).readAsStringSync();
        final blocks = _blocksIn(text);

        ok(0 < blocks.length,
            'expected at least one dart block in ' + label);

        final stats = _gate(label, blocks);

        ok(0 < (stats['runnable'] ?? 0),
            'expected at least one runnable dart block in ' +
                label +
                ' (a block that constructs the SDK or drives a client)');
      });
    }
  });
}
`)
  })
})


export {
  ReadmeExamplesTest
}
