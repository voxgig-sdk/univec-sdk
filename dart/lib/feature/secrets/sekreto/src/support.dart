// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/src/support.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// How a provider kind becomes a voxgig/plugin definition.
//
// This file is the whole bridge between the two libraries. A provider kind
// is a plugin `Definition` named after the kind; its `define` reads the
// instance's options as a `ProviderSpec`, builds the provider, and exports
// it under the key `provider`. `Sekreto` reads it back off the host. One
// helper makes every one of them, built-in or plugin, shipped or custom:
//
//     final mystore = providerplugin('mystore', (spec) => Mystore(spec.addr));
//
// A port of typescript/src/provider/support.ts, which is canonical.

import '../../plugin/plugin.dart' as plugin;

import 'provider.dart';
import 'sekreto.dart';
import 'spec.dart';

/// A voxgig/plugin definition.
///
/// plugin's value model is `dynamic`, and a definition is a map of `name` to
/// the kind and `define` to the callback - which is what makes a catalog a
/// data structure a document could produce. The alias exists so that a
/// `plugins` list reads as what it is rather than as
/// `List<Map<String, dynamic>>`.
typedef Definition = Map<String, dynamic>;

/// The export key under which a provider definition publishes the provider
/// it built. `Sekreto` reads `<ref>/provider` off the host.
const String PROVIDER_EXPORT = 'provider';

/// The voxgig/plugin error code a SekretoError travels under when it is
/// raised inside a definition's `define`.
///
/// plugin wraps a code-less error raised by a callback as
/// `plugin_define_failed`, and keeps one that already carries a code. A
/// provider that refuses its own configuration - `kv: 3`, a missing project
/// - raises a SekretoError, and the shared spec pins that message byte for
/// byte, so it must come back out of the host exactly as it went in.
/// `providerplugin` gives it this code on the way in; `Sekreto` takes it off
/// on the way out. Nowhere else catches and rewraps.
const String ERROR_CODE = 'sekreto_error';

/// A provider kind, as a voxgig/plugin definition.
///
/// Nothing runs at `activate`: a provider opens nothing until its first
/// lookup, so there is nothing to capture - a provider that does hold a
/// resource acquires it there and lets the instance scope unwind it.
Definition providerplugin(String kind, Provider Function(ProviderSpec) make) =>
    {
      'name': kind,
      // A one-argument closure, so plugin's `_run` sees a Function and calls
      // it with the instance.
      'define': (plugin.Inst inst) {
        final Provider provider;

        try {
          provider = make(specof(inst.options));
        } on SekretoError catch (err) {
          throw plugin.PluginError(
            ERROR_CODE,
            err.message,
            {'ref': inst.ref, 'cause': err.message},
          );
        }

        inst.export(PROVIDER_EXPORT, provider);
      },
    };

// --- the spec across the plugin boundary -----------------------------
//
// plugin's options are its own value model - a map of strings to null,
// bool, num, String, List and Map - and sekreto's spec is a typed class, so
// the two are written out field by field rather than reflected over.
// `optionsof` is what `Sekreto.declare` hands to `host.load`; `specof` is
// what a definition's `define` reads back. They are inverses, and the seam
// test `a provider spec survives the plugin boundary` is what says so - a
// field added to one and forgotten in the other would otherwise be lost in
// silence, and only for the kinds no conformance case exercises.

void _put(Map<String, dynamic> out, String key, Object? value) {
  if (null != value) {
    out[key] = value;
  }
}

String? _str(Map<String, dynamic> options, String key) {
  final value = options[key];
  return value is String ? value : null;
}

/// A ProviderSpec as plugin instance options.
Map<String, dynamic> optionsof(ProviderSpec spec) {
  final out = <String, dynamic>{};

  out['kind'] = spec.kind;
  _put(out, 'name', spec.name);
  _put(out, 'prefix', spec.prefix);
  _put(out, 'file', spec.file);
  _put(out, 'values',
      null == spec.values ? null : Map<String, dynamic>.from(spec.values!));
  _put(out, 'dir', spec.dir);
  _put(out, 'addr', spec.addr);
  _put(out, 'token', spec.token);
  _put(out, 'mount', spec.mount);
  _put(out, 'kv', spec.kv);
  _put(out, 'vaultnamespace', spec.vaultnamespace);

  final auth = spec.auth;
  if (null != auth) {
    final nested = <String, dynamic>{};
    nested['method'] = auth.method;
    _put(nested, 'mount', auth.mount);
    _put(nested, 'role', auth.role);
    _put(nested, 'jwt', auth.jwt);
    _put(nested, 'jwtfile', auth.jwtfile);
    _put(nested, 'roleid', auth.roleid);
    _put(nested, 'secretid', auth.secretid);
    out['auth'] = nested;
  }

  _put(out, 'command', spec.command);
  _put(out, 'profile', spec.profile);
  _put(out, 'backend', spec.backend);
  _put(out, 'reason', spec.reason);
  _put(out, 'namespace', spec.namespace);
  _put(out, 'home', spec.home);
  _put(out, 'region', spec.region);
  _put(out, 'keyid', spec.keyid);
  _put(out, 'secret', spec.secret);
  _put(out, 'session', spec.session);
  _put(out, 'project', spec.project);
  _put(out, 'vault', spec.vault);
  _put(out, 'tenant', spec.tenant);
  _put(out, 'clientid', spec.clientid);
  _put(out, 'clientsecret', spec.clientsecret);
  _put(out, 'loginaddr', spec.loginaddr);
  _put(out, 'imdsaddr', spec.imdsaddr);
  _put(out, 'metadataaddr', spec.metadataaddr);
  _put(out, 'apiversion', spec.apiversion);
  _put(out, 'config', spec.config);
  _put(out, 'environment', spec.environment);
  _put(out, 'path', spec.path);

  return out;
}

/// Plugin instance options as a ProviderSpec.
ProviderSpec specof(Map<String, dynamic> options) {
  final rawvalues = options['values'];
  final values = rawvalues is Map
      ? <String, String>{
          for (final entry in rawvalues.entries)
            '${entry.key}': '${entry.value}',
        }
      : null;

  final rawauth = options['auth'];
  final auth = rawauth is Map
      ? AuthSpec(
          method: rawauth['method'] is String ? rawauth['method'] as String : '',
          mount: rawauth['mount'] is String ? rawauth['mount'] as String : null,
          role: rawauth['role'] is String ? rawauth['role'] as String : null,
          jwt: rawauth['jwt'] is String ? rawauth['jwt'] as String : null,
          jwtfile:
              rawauth['jwtfile'] is String ? rawauth['jwtfile'] as String : null,
          roleid:
              rawauth['roleid'] is String ? rawauth['roleid'] as String : null,
          secretid: rawauth['secretid'] is String
              ? rawauth['secretid'] as String
              : null,
        )
      : null;

  final kv = options['kv'];

  return ProviderSpec(
    kind: _str(options, 'kind') ?? '',
    name: _str(options, 'name'),
    prefix: _str(options, 'prefix'),
    file: _str(options, 'file'),
    values: values,
    dir: _str(options, 'dir'),
    addr: _str(options, 'addr'),
    token: _str(options, 'token'),
    mount: _str(options, 'mount'),
    kv: kv is num ? kv.toInt() : null,
    vaultnamespace: _str(options, 'vaultnamespace'),
    auth: auth,
    command: _str(options, 'command'),
    profile: _str(options, 'profile'),
    backend: _str(options, 'backend'),
    reason: _str(options, 'reason'),
    namespace: _str(options, 'namespace'),
    home: _str(options, 'home'),
    region: _str(options, 'region'),
    keyid: _str(options, 'keyid'),
    secret: _str(options, 'secret'),
    session: _str(options, 'session'),
    project: _str(options, 'project'),
    vault: _str(options, 'vault'),
    tenant: _str(options, 'tenant'),
    clientid: _str(options, 'clientid'),
    clientsecret: _str(options, 'clientsecret'),
    loginaddr: _str(options, 'loginaddr'),
    imdsaddr: _str(options, 'imdsaddr'),
    metadataaddr: _str(options, 'metadataaddr'),
    apiversion: _str(options, 'apiversion'),
    config: _str(options, 'config'),
    environment: _str(options, 'environment'),
    path: _str(options, 'path'),
  );
}
