// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/onepassword.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// 1Password Connect, as a voxgig/plugin definition.
//
// A PLUGIN, not a built-in: it opens a socket. A `Sekreto` can build the
// `onepassword` kind only if the calling project imported this file and
// passed `onepassword` in the `plugins` option
// (docs/design/plugin-providers.md).
//
// A port of typescript/plugins/onepassword.ts, which is canonical.

import 'dart:async';

import '../src/addr.dart';
import '../src/json.dart';
import '../src/provider.dart';
import '../src/sekreto.dart';
import '../src/support.dart';

import 'httpjson.dart';

/// 1Password, through a Connect server.
///
/// The item titled `api.token` (titles keep their dots), in the named vault.
/// The value is the field with purpose PASSWORD, or the field labelled
/// `value`. A vault that cannot be found is an error - config names it, so
/// its absence is a broken store, not a missing secret.
class Onepassword extends Provider {
  final String? addr;
  final String? token;
  final String? vault;

  String? _vaultid;

  Onepassword({this.addr, this.token, this.vault});

  Map<String, String> _auth() => {'authorization': 'Bearer ${token ?? ''}'};

  Future<String> _resolvevault(String useaddr) async {
    final want = vault ?? '';
    if (want.isEmpty) {
      throw SekretoError('sekreto: onepassword: no vault');
    }

    final res = await fetchjson('GET', '$useaddr/v1/vaults', headers: _auth());

    final list = res.body.asarr;
    if (200 != res.status || null == list) {
      throw SekretoError(
        'sekreto: onepassword error: ${res.status}: listing vaults',
      );
    }

    for (final entry in list) {
      if (want == entry.dig('id').text || want == entry.dig('name').text) {
        return entry.dig('id').text ?? '';
      }
    }

    throw SekretoError('sekreto: onepassword: no vault named $want');
  }

  @override
  FutureOr<String?> lookup(String name) {
    checkname(name);

    final useaddr = trimslash(addr ?? '');
    if (useaddr.isEmpty) {
      throw SekretoError('sekreto: onepassword: no addr');
    }
    checkaddr(useaddr);

    return _read(useaddr, name);
  }

  Future<String?> _read(String useaddr, String name) async {
    var id = _vaultid;
    if (null == id) {
      id = await _resolvevault(useaddr);
      _vaultid = id;
    }

    final filter = uriescape('title eq "$name"');
    final found = await fetchjson(
      'GET',
      '$useaddr/v1/vaults/$id/items?filter=$filter',
      headers: _auth(),
    );

    final items = found.body.asarr;
    if (200 != found.status || null == items) {
      throw SekretoError(
        'sekreto: onepassword error: ${found.status}: finding $name',
      );
    }

    // An empty list is a miss: the vault is fine, the item is not there.
    if (items.isEmpty) {
      return null;
    }

    final itemid = items.first.dig('id').text ?? '';
    final item = await fetchjson(
      'GET',
      '$useaddr/v1/vaults/$id/items/$itemid',
      headers: _auth(),
    );

    if (200 != item.status) {
      throw SekretoError(
        'sekreto: onepassword error: ${item.status}: reading $name',
      );
    }

    final fields = item.body.dig('fields').asarr ?? const <Json>[];

    for (final field in fields) {
      if ('PASSWORD' == field.dig('purpose').asstr) {
        return field.dig('value').text;
      }
    }

    for (final field in fields) {
      if ('value' == field.dig('label').asstr) {
        return field.dig('value').text;
      }
    }

    return null;
  }

  @override
  String describe() => 'onepassword:${vault ?? ''}';
}

/// The `onepassword` provider kind. Pass it in `plugins` to name it in a
/// chain.
final Definition onepassword = providerplugin(
  'onepassword',
  (spec) => Onepassword(
    addr: spec.addr,
    token: spec.token,
    vault: spec.vault,
  ),
);
