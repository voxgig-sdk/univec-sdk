// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/doppler.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Doppler, as a voxgig/plugin definition.
//
// A PLUGIN, not a built-in: it opens a socket. A `Sekreto` can build the
// `doppler` kind only if the calling project imported this file and passed
// `doppler` in the `plugins` option (docs/design/plugin-providers.md).
//
// A port of typescript/plugins/doppler.ts, which is canonical.

import 'dart:async';

import '../src/addr.dart';
import '../src/json.dart';
import '../src/provider.dart';
import '../src/sekreto.dart';
import '../src/support.dart';

import 'httpjson.dart';

/// Doppler.
///
/// The whole config is downloaded once - Doppler's own bulk endpoint - and
/// answered from memory, like a remote .env: `api.token` is the `API_TOKEN`
/// entry. A service token is config-scoped, so project and config are only
/// needed with broader tokens.
class Doppler extends Provider {
  final String? token;
  final String? project;
  final String? config;
  final String? addr;

  Map<String, String>? _values;

  Doppler({this.token, this.project, this.config, this.addr});

  @override
  FutureOr<String?> lookup(String name) {
    final loaded = _values;
    if (null != loaded) {
      return loaded[envkey(name)];
    }

    final useaddr = trimslash(first([addr, 'https://api.doppler.com']));
    checkaddr(useaddr);

    return _load(useaddr).then((values) => values[envkey(name)]);
  }

  Future<Map<String, String>> _load(String useaddr) async {
    var url = '$useaddr/v3/configs/config/secrets/download?format=json';
    if (null != project && project!.isNotEmpty) {
      url += '&project=${uriescape(project!)}';
    }
    if (null != config && config!.isNotEmpty) {
      url += '&config=${uriescape(config!)}';
    }

    final res = await fetchjson('GET', url,
        headers: {'authorization': 'Bearer ${token ?? ''}'});

    final body = res.body.asobj;
    if (200 != res.status || null == body) {
      throw SekretoError('sekreto: doppler error: ${res.status}');
    }

    final loaded = <String, String>{};
    body.forEach((key, value) {
      // A null value is not a secret; it is a declared name with nothing
      // behind it.
      final text = value.text;
      if (null != text) {
        loaded[key] = text;
      }
    });

    // Only a successful load is remembered, so a failure retries.
    _values = loaded;
    return loaded;
  }

  @override
  String describe() {
    if (null != project && project!.isNotEmpty) {
      return 'doppler:$project/${config ?? ''}';
    }
    return 'doppler';
  }
}

/// The `doppler` provider kind. Pass it in `plugins` to name it in a chain.
final Definition doppler = providerplugin(
  'doppler',
  (spec) => Doppler(
    token: spec.token,
    project: spec.project,
    config: spec.config,
    addr: spec.addr,
  ),
);
