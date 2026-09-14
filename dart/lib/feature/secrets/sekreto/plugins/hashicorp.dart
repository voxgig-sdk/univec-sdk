// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/hashicorp.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// HashiCorp Vault, as a voxgig/plugin definition.
//
// A PLUGIN, not a built-in: it opens a socket. A `Sekreto` can build the
// `hashicorp` kind only if the calling project imported this file and passed
// `hashicorp` in the `plugins` option (docs/design/plugin-providers.md).
//
// A port of typescript/plugins/hashicorp.ts, which is canonical.

import 'dart:async';
import 'dart:io';

import '../src/addr.dart';
import '../src/json.dart';
import '../src/provider.dart';
import '../src/sekreto.dart';
import '../src/spec.dart';
import '../src/support.dart';

import 'httpjson.dart';

/// HashiCorp Vault.
///
/// KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
/// takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
/// `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
/// here" - a miss - so a vault can sit in a chain with fallbacks.
///
/// A Vault Enterprise namespace rides the X-Vault-Namespace header, on
/// logins as well as reads.
///
/// Instead of being handed a token, the provider can log in: Kubernetes auth
/// (the pod's service-account JWT, from its conventional path) or AppRole. A
/// failed login is an error, never a miss - it means this store could not
/// answer at all.
class Hashicorp extends Provider {
  final String addr;
  final String mount;
  final int kv;
  final String? vaultnamespace;
  final AuthSpec? auth;

  // The working token: a configured token is kept forever, a logged-in token
  // is renewed shortly before its lease runs out - a long-running process
  // must not keep presenting a token the vault already expired.
  String? _livetoken;
  int _renewat = NEVER;

  Hashicorp(
    this.addr, {
    String? token,
    String? mount,
    int? kv,
    this.vaultnamespace,
    this.auth,
  })  : mount = (null == mount || mount.isEmpty) ? 'secret' : mount,
        kv = kv ?? 2,
        _livetoken = (null == token || token.isEmpty) ? null : token {
    // A version typo like kv: 3 must not quietly behave as v2 and turn its
    // 404s into misses; there is nothing safe to assume it meant.
    if (1 != this.kv && 2 != this.kv) {
      throw SekretoError('sekreto: hashicorp: unsupported kv version: ${this.kv}');
    }
  }

  Map<String, String> _baseheaders() {
    if (null != vaultnamespace && vaultnamespace!.isNotEmpty) {
      return {'X-Vault-Namespace': vaultnamespace!};
    }
    return {};
  }

  Future<String> _login() async {
    final use = auth;
    if (null == use) {
      throw SekretoError('sekreto: hashicorp: no token and no auth method');
    }

    final authmount = first([use.mount, use.method]);
    final url = '${trimslash(addr)}/v1/auth/$authmount/login';

    final Json body;

    switch (use.method) {
      case 'kubernetes':
        String jwt;
        final given = use.jwt;

        if (null != given) {
          jwt = given;
        } else {
          final file = use.jwtfile ??
              '/var/run/secrets/kubernetes.io/serviceaccount/token';
          try {
            jwt = File(file).readAsStringSync().trim();
          } on FileSystemException {
            throw SekretoError(
              'sekreto: hashicorp: cannot read jwt file $file',
            );
          }
        }

        body = JsonObj({
          'role': JsonStr(use.role ?? ''),
          'jwt': JsonStr(jwt),
        });

      case 'approle':
        body = JsonObj({
          'role_id': JsonStr(use.roleid ?? ''),
          'secret_id': JsonStr(use.secretid ?? ''),
        });

      default:
        throw SekretoError(
          'sekreto: hashicorp: unknown auth method: ${use.method}',
        );
    }

    final res = await fetchjson(
      'POST',
      url,
      headers: _baseheaders(),
      body: jsonstringify(body),
    );

    final got = res.body.dig('auth', 'client_token').text;
    if (200 != res.status || null == got || got.isEmpty) {
      throw SekretoError('sekreto: hashicorp login failed: ${res.status}: $url');
    }

    _renewat = renewtime(res.body.dig('auth', 'lease_duration'));

    return got;
  }

  @override
  FutureOr<String?> lookup(String name) {
    // Refused before anything is dialled, and synchronously, so a misspelled
    // address is a configuration error rather than a network one.
    checkaddr(addr);
    return _read(name);
  }

  Future<String?> _read(String name) async {
    if (null == _livetoken || DateTime.now().millisecondsSinceEpoch >= _renewat) {
      _livetoken = await _login();
    }

    final ref = vaultref(name);
    final base = '${trimslash(addr)}/v1/$mount';
    final url = 1 == kv ? '$base/${ref.path}' : '$base/data/${ref.path}';

    final headers = _baseheaders();
    headers['X-Vault-Token'] = _livetoken ?? '';

    final res = await fetchjson('GET', url, headers: headers);

    if (404 == res.status) {
      return null;
    }
    if (200 != res.status) {
      throw SekretoError('sekreto: hashicorp error: ${res.status}: $url');
    }

    final data =
        1 == kv ? res.body.dig('data') : res.body.dig('data', 'data');

    return data.dig(ref.field).text;
  }

  @override
  String describe() => 'hashicorp:$addr/$mount';
}

/// The `hashicorp` provider kind. Pass it in `plugins` to name it in a
/// chain: `sekreto(chain, plugins: [hashicorp])`.
final Definition hashicorp = providerplugin(
  'hashicorp',
  (spec) => Hashicorp(
    spec.addr ?? '',
    token: spec.token,
    mount: spec.mount,
    kv: spec.kv,
    vaultnamespace: spec.vaultnamespace,
    auth: spec.auth,
  ),
);
