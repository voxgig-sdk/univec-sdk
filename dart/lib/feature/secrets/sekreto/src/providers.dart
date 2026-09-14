// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/src/providers.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// THE BUILT-IN PROVIDER KINDS - the same four in every port.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or null to mean "ask the next one". Nothing else about a
// provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file or a mounted secret directory.
//
// What makes a kind built in is that it reads AT MOST A LOCAL FILE: no
// socket, no TLS, no crypto, no child process. These four are the floor
// every chain stands on, and a chain that reads secrets from options, the
// environment, a plaintext `.env` and a mounted secret directory works with
// no plugin loaded at all. Everything else - the vault clients, the cloud
// stores, the two CLIs, and `sigv4` with them - is a voxgig/plugin
// definition under `plugins/`, and this file is the reason the core imports
// none of it (docs/design/plugin-providers.md).
//
// Two failure shapes, and they are never interchangeable. A store that does
// not hold the secret is a MISS (null) - the chain carries on. A store that
// could not answer - bad credentials, unreachable host, missing
// configuration - is an ERROR: falling through there would quietly reach
// for a weaker store.
//
// A port of typescript/src/provider/, which is canonical.

import 'dart:io';

import 'provider.dart';
import 'sekreto.dart';
import 'support.dart';

/// An environment variable, or null.
String? getenv(String name) => Platform.environment[name];

/// What a failure has to say for itself, never the empty string.
String why(Object err) {
  if (err is FileSystemException) {
    final os = err.osError;
    return null != os ? os.message : err.message;
  }
  if (err is SocketException) {
    final os = err.osError;
    return null != os ? os.message : err.message;
  }
  final text = '$err';
  return text.isEmpty ? '$err.runtimeType' : text;
}

// The two errno values that mean "no secrets here" rather than "I could not
// answer". A path that is not there, and a path whose parent is a plain
// file, are both absence; permission denied (EACCES) and "is a directory"
// (EISDIR) are not, and must raise rather than fall through to a weaker
// store.
const int _ENOENT = 2;
const int _ENOTDIR = 20;

bool absent(FileSystemException err) {
  final code = err.osError?.errorCode;
  return _ENOENT == code || _ENOTDIR == code;
}

/// `<dir>/<name>`, with an empty dir meaning the working directory.
String joinpath(String dir, String name) {
  if (dir.isEmpty) {
    return name;
  }
  return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
}

// ------------------------------------------------------------ the kinds

/// Environment variables: `api.token` from `API_TOKEN`.
class Env extends Provider {
  final String? prefix;

  /// An injected environment, for tests. The spec never passes one.
  final Map<String, String>? source;

  Env({this.prefix, this.source});

  @override
  String? lookup(String name) {
    final key = envkey(name, prefix);
    return null == source ? getenv(key) : source![key];
  }

  @override
  String describe() =>
      'env${(null != prefix && prefix!.isNotEmpty) ? ':$prefix' : ''}';
}

/// A `.env` file, read once, keyed exactly like the environment.
class Dotenv extends Provider {
  final String file;
  final String? prefix;

  // Read LAZILY, on the first lookup. An eager read would open whatever
  // `.env` happens to sit in the working directory just because a dotenv
  // provider is in a chain that is never read from.
  Map<String, String>? _values;

  Dotenv(this.file, {this.prefix});

  Map<String, String> _load() {
    final loaded = _values;
    if (null != loaded) {
      return loaded;
    }

    Map<String, String> values;

    try {
      values = parsedotenv(File(file).readAsStringSync());
    } on FileSystemException catch (err) {
      // An absent file - or an absent directory - means "no secrets here",
      // exactly like the file provider. Anything else (permission denied, an
      // unreadable mount) is a store that could not answer.
      if (!absent(err)) {
        throw SekretoError(
          'sekreto: dotenv provider cannot read $file: ${why(err)}',
        );
      }
      values = <String, String>{};
    }

    _values = values;
    return values;
  }

  @override
  String? lookup(String name) => _load()[envkey(name, prefix)];

  @override
  String describe() => 'dotenv:$file';
}

/// Literal values, keyed like environment variables. The spec uses this to
/// test chain behaviour without touching the outside world.
class Memory extends Provider {
  final Map<String, String> values;
  final String? prefix;

  Memory({Map<String, String>? source, this.prefix})
      : values = source ?? const {};

  @override
  String? lookup(String name) => values[envkey(name, prefix)];

  @override
  String describe() =>
      'memory${(null != prefix && prefix!.isNotEmpty) ? ':$prefix' : ''}';
}

/// A directory of one-secret-per-file entries, keyed like the environment:
/// `api.token` reads `<dir>/API_TOKEN`.
///
/// This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
/// secret, and a systemd credentials directory, so those all work with no
/// further configuration. Read on every lookup and never cached: a mounted
/// secret is rotated underneath a running process.
///
/// One trailing newline is stripped - tools that write these files disagree
/// about it, and a newline is never part of a secret on purpose.
class SecretFile extends Provider {
  final String dir;
  final String? prefix;

  SecretFile(this.dir, {this.prefix});

  @override
  String? lookup(String name) {
    final path = joinpath(dir, envkey(name, prefix));

    final String body;

    try {
      body = File(path).readAsStringSync();
    } on FileSystemException catch (err) {
      if (absent(err)) {
        return null;
      }
      throw SekretoError(
        'sekreto: file provider cannot read $path: ${why(err)}',
      );
    }

    if (body.endsWith('\r\n')) {
      return body.substring(0, body.length - 2);
    }
    if (body.endsWith('\n')) {
      return body.substring(0, body.length - 1);
    }
    return body;
  }

  @override
  String describe() => 'file:$dir';
}

// ------------------------------------------------------- the definitions

/// The four built-in kinds, as voxgig/plugin definitions - made by exactly
/// the same helper as every plugin kind and every custom one.
///
/// `Sekreto` puts these into its catalog first, then whatever `plugins`
/// handed in, so a plugin naming a built-in kind replaces it: a host
/// substituting an implementation, never an accident, because these four
/// names are documented.
final List<Definition> BUILTINS = [
  providerplugin('env', (spec) => Env(prefix: spec.prefix)),
  providerplugin(
      'memory', (spec) => Memory(source: spec.values, prefix: spec.prefix)),
  providerplugin(
      'dotenv', (spec) => Dotenv(spec.file ?? '.env', prefix: spec.prefix)),
  providerplugin(
      'file', (spec) => SecretFile(spec.dir ?? '', prefix: spec.prefix)),
];

/// Every kind this library ships, built in or as a plugin, so that a kind
/// sekreto has never heard of can be told from one that exists as a plugin
/// and was not passed in.
///
/// Ten strings, not ten imports: the core knows the plugin NAMES without
/// reaching a single plugin file.
class KINDS {
  static const List<String> builtin = ['env', 'memory', 'dotenv', 'file'];

  static const List<String> plugin = [
    'hashicorp',
    'boru',
    'awssecrets',
    'awsparams',
    'gcpsecrets',
    'azuresecrets',
    'onepassword',
    'doppler',
    'infisical',
    'secretspec',
  ];
}
