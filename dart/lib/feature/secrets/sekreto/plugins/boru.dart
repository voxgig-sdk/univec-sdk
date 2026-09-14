// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/boru.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// A boru vault, as a voxgig/plugin definition.
//
// A PLUGIN, not a built-in: it spawns a child process, or opens a socket.
// A `Sekreto` can build the `boru` kind only if the calling project
// imported this file and passed `boru` in the `plugins` option
// (docs/design/plugin-providers.md).
//
// A port of typescript/plugins/boru.ts, which is canonical.

import 'dart:async';

import '../src/addr.dart';
import '../src/json.dart';
import '../src/provider.dart';
import '../src/sekreto.dart';
import '../src/support.dart';

import 'httpjson.dart';

/// Does this boru failure mean "no such secret" rather than "I could not
/// answer"? Matched on boru's own wording for a missing alias.
bool borumiss(String reason) => reason.contains('no alias named');

/// A boru vault (https://github.com/boru-lang/boru).
///
/// Two ways in, both boru's own.
///
/// With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
/// secret on stdout and nothing else. The passphrase is read by boru itself
/// from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as config and
/// never puts it on a command line, where it would show up in the process
/// table.
///
/// With an `addr`, boru's wire protocol: `boru vault serve` publishes a
/// read-only, HashiCorp-shaped provision API, authenticated by a capability
/// token from `boru vault grant`. A sekreto name is already a valid boru
/// alias, and boru aliases keep their dots, so `api.token` is the single
/// path segment `api.token` - not the `api`/`token` split a HashiCorp KV
/// gets. The value is the `value` field. A 404 is a miss; anything else the
/// server refuses (a revoked capability, a sealed vault) is an error.
class Boru extends Provider {
  final String command;
  final String? namespace;
  final String? home;
  final String addr;
  final String token;
  final String mount;

  Boru({
    String? command,
    this.namespace,
    this.home,
    String? addr,
    String? token,
    String? mount,
  })  : command = (null == command || command.isEmpty) ? 'boru' : command,
        addr = null == addr ? '' : trimslash(addr),
        token = token ?? '',
        mount = (null == mount || mount.isEmpty) ? 'secret' : mount;

  @override
  FutureOr<String?> lookup(String name) {
    checkname(name);

    if (addr.isNotEmpty) {
      checkaddr(addr);
      return _wire(name);
    }

    final space = namespace;
    final alias =
        (null != space && space.isNotEmpty) ? '$space:$name' : name;

    final ran = runcmd(
      [command, 'vault', 'get', '--reveal', alias],
      command,
      // Merged over the parent environment, not replacing it: boru needs
      // the rest of it, BORU_VAULT_PASSPHRASE included.
      extraenv: (null != home && home!.isNotEmpty)
          ? {'BORU_HOME': home!}
          : null,
    );

    if (0 == ran.status) {
      // boru prints the value and one newline, and nothing else.
      return dropsuffix(ran.out, '\n');
    }

    // "no alias named" is boru saying it does not hold this secret, which is
    // a miss: the chain carries on to the next provider. A locked vault or a
    // wrong passphrase is not a miss - treating it as one would fall through
    // to a weaker store without saying so.
    if (borumiss(ran.why)) {
      return null;
    }

    throw SekretoError(
      'sekreto: boru vault error: '
      '${ran.why.isEmpty ? 'exit ${ran.status}' : ran.why}',
    );
  }

  Future<String?> _wire(String name) async {
    // The dotted name stays one path segment: boru aliases keep dots.
    final space = namespace;
    final alias =
        (null != space && space.isNotEmpty) ? '$space/$name' : name;
    final url = '$addr/v1/$mount/data/$alias';

    final res = await fetchjson('GET', url, headers: {'X-Vault-Token': token});

    if (404 == res.status) {
      return null;
    }
    if (200 != res.status) {
      throw SekretoError('sekreto: boru serve error: ${res.status}: $url');
    }

    return res.body.dig('data', 'data', 'value').text;
  }

  @override
  String describe() {
    if (addr.isNotEmpty) {
      return 'boru:$addr';
    }
    return 'boru${(null != namespace && namespace!.isNotEmpty) ? ':$namespace' : ''}';
  }
}

/// The `boru` provider kind. Pass it in `plugins` to name it in a chain.
final Definition boru = providerplugin(
  'boru',
  (spec) => Boru(
    command: spec.command,
    namespace: spec.namespace,
    home: spec.home,
    addr: spec.addr,
    token: spec.token,
    mount: spec.mount,
  ),
);
