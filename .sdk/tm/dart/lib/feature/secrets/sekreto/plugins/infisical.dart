// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/infisical.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Infisical, as a voxgig/plugin definition.
//
// A PLUGIN, not a built-in: it opens a socket. A `Sekreto` can build the
// `infisical` kind only if the calling project imported this file and
// passed `infisical` in the `plugins` option
// (docs/design/plugin-providers.md).
//
// A port of typescript/plugins/infisical.ts, which is canonical.

import 'dart:async';

import '../src/addr.dart';
import '../src/json.dart';
import '../src/provider.dart';
import '../src/sekreto.dart';
import '../src/support.dart';

import 'httpjson.dart';

/// Infisical.
///
/// `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
/// convention is environment-style keys) at a secret path in one environment
/// of a project. Auth is a token, or a universal-auth (machine identity)
/// login with clientid/clientsecret.
class Infisical extends Provider {
  final String? addr;
  final String? token;
  final String? clientid;
  final String? clientsecret;
  final String? project;
  final String? environment;
  final String? path;

  // A configured token is kept forever; a universal-auth token carries
  // expiresIn and is renewed shortly before it runs out.
  String? _livetoken;
  int _renewat = NEVER;

  Infisical({
    this.addr,
    this.token,
    this.clientid,
    this.clientsecret,
    this.project,
    this.environment,
    this.path,
  });

  Future<String> _login(String useaddr) async {
    if (null != token && token!.isNotEmpty) {
      return token!;
    }

    if (null == clientid ||
        clientid!.isEmpty ||
        null == clientsecret ||
        clientsecret!.isEmpty) {
      throw SekretoError(
        'sekreto: infisical: no token and no client credentials',
      );
    }

    final body = JsonObj({
      'clientId': JsonStr(clientid!),
      'clientSecret': JsonStr(clientsecret!),
    });

    final res = await fetchjson(
      'POST',
      '$useaddr/api/v1/auth/universal-auth/login',
      headers: {'content-type': 'application/json'},
      body: jsonstringify(body),
    );

    final got = res.body.dig('accessToken').text;
    if (200 != res.status || null == got || got.isEmpty) {
      throw SekretoError('sekreto: infisical login failed: ${res.status}');
    }

    // camelCase, unlike everyone else's expires_in.
    _renewat = renewtime(res.body.dig('expiresIn'));

    return got;
  }

  @override
  FutureOr<String?> lookup(String name) {
    final useaddr = trimslash(first([addr, 'https://app.infisical.com']));
    checkaddr(useaddr);

    final useproject = project ?? '';
    final useenvironment = environment ?? '';
    if (useproject.isEmpty || useenvironment.isEmpty) {
      throw SekretoError('sekreto: infisical: no project/environment');
    }

    return _read(useaddr, useproject, useenvironment, name);
  }

  Future<String?> _read(
    String useaddr,
    String useproject,
    String useenvironment,
    String name,
  ) async {
    if (null == _livetoken || DateTime.now().millisecondsSinceEpoch >= _renewat) {
      _livetoken = await _login(useaddr);
    }

    final url = '$useaddr/api/v3/secrets/raw/${envkey(name)}'
        '?workspaceId=${uriescape(useproject)}'
        '&environment=${uriescape(useenvironment)}'
        '&secretPath=${uriescape(first([path, '/']))}';

    final res = await fetchjson('GET', url,
        headers: {'authorization': 'Bearer ${_livetoken ?? ''}'});

    if (404 == res.status) {
      return null;
    }
    if (200 != res.status) {
      throw SekretoError('sekreto: infisical error: ${res.status}');
    }

    return res.body.dig('secret', 'secretValue').text;
  }

  @override
  String describe() => 'infisical:${project ?? ''}/${environment ?? ''}';
}

/// The `infisical` provider kind. Pass it in `plugins` to name it in a
/// chain.
final Definition infisical = providerplugin(
  'infisical',
  (spec) => Infisical(
    addr: spec.addr,
    token: spec.token,
    clientid: spec.clientid,
    clientsecret: spec.clientsecret,
    project: spec.project,
    environment: spec.environment,
    path: spec.path,
  ),
);
