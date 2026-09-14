// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/gcpsecrets.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// GCP Secret Manager, as a voxgig/plugin definition.
//
// A PLUGIN, not a built-in: it opens a socket. A `Sekreto` can build the
// `gcpsecrets` kind only if the calling project imported this file and
// passed `gcpsecrets` in the `plugins` option
// (docs/design/plugin-providers.md).
//
// A port of typescript/plugins/gcpsecrets.ts, which is canonical.

import 'dart:async';

import '../src/addr.dart';
import '../src/json.dart';
import '../src/provider.dart';
import '../src/providers.dart';
import '../src/sekreto.dart';
import '../src/support.dart';

import 'httpjson.dart';

/// GCP Secret Manager.
///
/// `api.token` reads secret `api_token` (dots flattened to `_`; Secret
/// Manager ids have no hierarchy and reject dots), latest version. The token
/// comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the GCE/GKE
/// metadata server - so on Google's own platform no credential configuration
/// is needed at all.
///
/// The metadata call itself is plain http to a link-local host by platform
/// design; no credential rides on it, so `checkaddr` guards the Secret
/// Manager address instead.
class Gcpsecrets extends Provider {
  final String? project;
  final String? token;
  final String? addr;
  final String? metadataaddr;

  // A configured token is kept forever; a metadata-server token carries
  // expires_in and is renewed shortly before it runs out.
  String? _livetoken;
  int _renewat = NEVER;

  Gcpsecrets({this.project, this.token, this.addr, this.metadataaddr});

  String _metadataaddr() {
    if (null != metadataaddr && metadataaddr!.isNotEmpty) {
      return metadataaddr!;
    }

    final host = getenv('GCE_METADATA_HOST');
    if (null != host && host.isNotEmpty) {
      return 'http://$host';
    }

    return 'http://metadata.google.internal';
  }

  Future<String> _login() async {
    final configured = first([token, getenv('GOOGLE_OAUTH_ACCESS_TOKEN')]);
    if (configured.isNotEmpty) {
      return configured;
    }

    final url = '${trimslash(_metadataaddr())}'
        '/computeMetadata/v1/instance/service-accounts/default/token';

    final res =
        await fetchjson('GET', url, headers: {'Metadata-Flavor': 'Google'});

    final got = res.body.dig('access_token').text;
    if (200 != res.status || null == got || got.isEmpty) {
      throw SekretoError(
        'sekreto: gcp: no token and metadata server did not answer',
      );
    }

    _renewat = renewtime(res.body.dig('expires_in'));

    return got;
  }

  @override
  FutureOr<String?> lookup(String name) {
    final useproject = project ?? '';
    if (useproject.isEmpty) {
      throw SekretoError('sekreto: gcp: no project');
    }

    final useaddr = first([addr, 'https://secretmanager.googleapis.com']);
    checkaddr(useaddr);

    return _read(useproject, useaddr, name);
  }

  Future<String?> _read(String useproject, String useaddr, String name) async {
    if (null == _livetoken || DateTime.now().millisecondsSinceEpoch >= _renewat) {
      _livetoken = await _login();
    }

    final url = '${trimslash(useaddr)}/v1/projects/$useproject/secrets/'
        '${flatname(name, '_')}/versions/latest:access';

    final res = await fetchjson('GET', url,
        headers: {'authorization': 'Bearer ${_livetoken ?? ''}'});

    if (404 == res.status) {
      return null;
    }
    if (200 != res.status) {
      throw SekretoError('sekreto: gcp error: ${res.status}: $url');
    }

    final data = res.body.dig('payload', 'data').asstr;
    if (null == data) {
      return null;
    }

    final decoded = unbase64(data);
    if (null == decoded) {
      throw SekretoError('sekreto: gcp: undecodable secret');
    }

    return decoded;
  }

  @override
  String describe() => 'gcpsecrets:${project ?? ''}';
}

/// The `gcpsecrets` provider kind. Pass it in `plugins` to name it in a
/// chain.
final Definition gcpsecrets = providerplugin(
  'gcpsecrets',
  (spec) => Gcpsecrets(
    project: spec.project,
    token: spec.token,
    addr: spec.addr,
    metadataaddr: spec.metadataaddr,
  ),
);
