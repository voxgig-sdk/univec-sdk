// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/azuresecrets.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Azure Key Vault, as a voxgig/plugin definition.
//
// A PLUGIN, not a built-in: it opens a socket. A `Sekreto` can build the
// `azuresecrets` kind only if the calling project imported this file and
// passed `azuresecrets` in the `plugins` option
// (docs/design/plugin-providers.md).
//
// A port of typescript/plugins/azuresecrets.ts, which is canonical.

import 'dart:async';

import '../src/addr.dart';
import '../src/json.dart';
import '../src/provider.dart';
import '../src/sekreto.dart';
import '../src/support.dart';

import 'httpjson.dart';

/// The Key Vault audience an Azure token is minted for.
const String RESOURCE = 'https://vault.azure.net';

/// Azure Key Vault.
///
/// `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
/// names allow nothing else), current version. The token comes from config,
/// then a client-credentials login when tenant/clientid/clientsecret are
/// given, then the IMDS managed-identity endpoint - so on Azure's own
/// platform no credential configuration is needed.
///
/// As with GCP, the IMDS call is plain http to a link-local host by platform
/// design and carries no credential; the login and vault addresses are
/// `checkaddr`-guarded.
class Azuresecrets extends Provider {
  final String? vault;
  final String? token;
  final String? tenant;
  final String? clientid;
  final String? clientsecret;
  final String? loginaddr;
  final String? imdsaddr;
  final String? apiversion;

  // A configured token is kept forever; logged-in and IMDS tokens carry
  // expires_in and are renewed shortly before they run out.
  String? _livetoken;
  int _renewat = NEVER;

  Azuresecrets({
    this.vault,
    this.token,
    this.tenant,
    this.clientid,
    this.clientsecret,
    this.loginaddr,
    this.imdsaddr,
    this.apiversion,
  });

  bool get _hasclient =>
      null != tenant &&
      tenant!.isNotEmpty &&
      null != clientid &&
      clientid!.isNotEmpty &&
      null != clientsecret &&
      clientsecret!.isNotEmpty;

  Future<String> _login() async {
    if (null != token && token!.isNotEmpty) {
      return token!;
    }

    if (_hasclient) {
      final useloginaddr =
          first([loginaddr, 'https://login.microsoftonline.com']);
      checkaddr(useloginaddr);

      final url = '${trimslash(useloginaddr)}/${tenant!}/oauth2/v2.0/token';
      final form = 'grant_type=client_credentials'
          '&client_id=${uriescape(clientid!)}'
          '&client_secret=${uriescape(clientsecret!)}'
          '&scope=${uriescape('$RESOURCE/.default')}';

      final res = await fetchjson(
        'POST',
        url,
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: form,
      );

      final got = res.body.dig('access_token').text;
      if (200 != res.status || null == got || got.isEmpty) {
        throw SekretoError('sekreto: azure login failed: ${res.status}');
      }

      _renewat = renewtime(res.body.dig('expires_in'));
      return got;
    }

    final imds = '${trimslash(first([imdsaddr, 'http://169.254.169.254']))}'
        '/metadata/identity/oauth2/token?api-version=2018-02-01'
        '&resource=${uriescape(RESOURCE)}';

    final res = await fetchjson('GET', imds, headers: {'Metadata': 'true'});

    final got = res.body.dig('access_token').text;
    if (200 != res.status || null == got || got.isEmpty) {
      throw SekretoError(
        'sekreto: azure: no token, no client credentials, and IMDS did not answer',
      );
    }

    // IMDS sends expires_in as a STRING, where everyone else sends a number.
    _renewat = renewtime(res.body.dig('expires_in'));
    return got;
  }

  @override
  FutureOr<String?> lookup(String name) {
    final usevault = vault ?? '';
    if (usevault.isEmpty) {
      throw SekretoError('sekreto: azure: no vault');
    }

    // Only an explicit scheme is a URL; a vault NAMED httpvault must still
    // become https://httpvault.vault.azure.net.
    final vaulturl =
        (usevault.startsWith('http://') || usevault.startsWith('https://'))
            ? usevault
            : 'https://$usevault.vault.azure.net';
    checkaddr(vaulturl);

    return _read(vaulturl, name);
  }

  Future<String?> _read(String vaulturl, String name) async {
    if (null == _livetoken || DateTime.now().millisecondsSinceEpoch >= _renewat) {
      _livetoken = await _login();
    }

    final url = '${trimslash(vaulturl)}/secrets/${flatname(name, '-')}'
        '?api-version=${first([apiversion, '7.4'])}';

    final res = await fetchjson('GET', url,
        headers: {'authorization': 'Bearer ${_livetoken ?? ''}'});

    if (404 == res.status) {
      return null;
    }
    if (200 != res.status) {
      throw SekretoError('sekreto: azure error: ${res.status}: ${bare(url)}');
    }

    return res.body.dig('value').text;
  }

  @override
  String describe() => 'azuresecrets:${vault ?? ''}';
}

/// The `azuresecrets` provider kind. Pass it in `plugins` to name it in a
/// chain.
final Definition azuresecrets = providerplugin(
  'azuresecrets',
  (spec) => Azuresecrets(
    vault: spec.vault,
    token: spec.token,
    tenant: spec.tenant,
    clientid: spec.clientid,
    clientsecret: spec.clientsecret,
    loginaddr: spec.loginaddr,
    imdsaddr: spec.imdsaddr,
    apiversion: spec.apiversion,
  ),
);
