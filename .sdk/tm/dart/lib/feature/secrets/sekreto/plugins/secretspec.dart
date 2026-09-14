// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/secretspec.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// SecretSpec, as a voxgig/plugin definition.
//
// A PLUGIN, not a built-in: it spawns a child process. A `Sekreto` can
// build the `secretspec` kind only if the calling project imported this
// file and passed `secretspec` in the `plugins` option
// (docs/design/plugin-providers.md).
//
// A port of typescript/plugins/secretspec.ts, which is canonical.

import '../src/provider.dart';
import '../src/sekreto.dart';
import '../src/support.dart';

import 'httpjson.dart';

/// Does this SecretSpec failure mean "no such secret" rather than "I could
/// not answer"?
///
/// SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
/// not declare and one declared with no value, and both are misses: this
/// store does not hold it, so the chain carries on.
///
/// MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
/// `Provider backend 'keyring' not found`, which is a store that could not
/// answer at all - and reading that as a miss is the worst failure this
/// library has, because the chain then falls through to a weaker store
/// without saying so. The key is required to appear, so the two cannot be
/// confused.
bool secretspecmiss(String reason, String key) =>
    reason.contains("Secret '$key' not found");

/// SecretSpec (https://secretspec.dev).
///
/// SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
/// project needs - plus a chain of its own backends to satisfy them from.
/// That makes it the same shape as sekreto one level down, and the reason to
/// support it is the same reason sekreto exists: a project that has already
/// declared its secrets there should not have to declare them again here.
///
/// A reason is required, not optional: SecretSpec records every read in an
/// audit log and refuses to read at all without one. sekreto sends `sekreto`
/// unless told otherwise, so the audit trail says which tool asked.
class Secretspec extends Provider {
  final String command;
  final String? file;
  final String? profile;
  final String? backend;
  final String? reason;
  final String? prefix;

  Secretspec({
    String? command,
    this.file,
    this.profile,
    this.backend,
    this.reason,
    this.prefix,
  }) : command = (null == command || command.isEmpty) ? 'secretspec' : command;

  @override
  String? lookup(String name) {
    final key = envkey(name, prefix);

    // The order is SecretSpec's: --file belongs to the program, before the
    // subcommand; everything else belongs to `get`.
    final argv = <String>[command];
    if (null != file && file!.isNotEmpty) {
      argv.addAll(['--file', file!]);
    }
    argv.addAll(['get', key]);
    if (null != backend && backend!.isNotEmpty) {
      argv.addAll(['--provider', backend!]);
    }
    if (null != profile && profile!.isNotEmpty) {
      argv.addAll(['--profile', profile!]);
    }
    argv.addAll(['--reason', first([reason, 'sekreto'])]);

    final ran = runcmd(argv, command);

    if (0 == ran.status) {
      // The value and one newline, and nothing else.
      return dropsuffix(ran.out, '\n');
    }

    if (secretspecmiss(ran.why, key)) {
      return null;
    }

    throw SekretoError(
      'sekreto: secretspec error: '
      '${ran.why.isEmpty ? 'exit ${ran.status}' : ran.why}',
    );
  }

  @override
  String describe() =>
      'secretspec${(null != backend && backend!.isNotEmpty) ? ':$backend' : ''}';
}

/// The `secretspec` provider kind. Pass it in `plugins` to name it in a
/// chain.
final Definition secretspec = providerplugin(
  'secretspec',
  (spec) => Secretspec(
    command: spec.command,
    file: spec.file,
    profile: spec.profile,
    backend: spec.backend,
    reason: spec.reason,
    prefix: spec.prefix,
  ),
);
