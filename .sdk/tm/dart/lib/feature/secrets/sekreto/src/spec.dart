// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/src/spec.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The declarative form of a provider, and the credentials it may carry.
//
// `ProviderSpec` is what a config file, the shared spec and an app's own
// chain description all look like: `kind` picks the provider and everything
// else is that kind's own. A plugin instance reads it back as
// `inst.options` (see support.dart).
//
// IN THE CORE, and not because the core builds every kind - it builds four.
// A spec is the SHAPE a chain is declared in, so a chain a plugin will
// build is still described here; the plugin reads it back through the same
// pair of converters every other kind uses.
//
// A port of typescript/src/provider/support.ts, which is canonical.

/// Logging in to a vault instead of being handed a token. `method` is
/// `kubernetes` or `approle`; `mount` defaults to the method name.
class AuthSpec {
  final String method;
  final String? mount;

  /// kubernetes: the Vault role to log in as.
  final String? role;

  /// kubernetes: the service-account JWT itself (tests).
  final String? jwt;

  /// kubernetes: where the JWT lives; the conventional pod path by default.
  final String? jwtfile;

  /// approle: the role and secret ids.
  final String? roleid;
  final String? secretid;

  const AuthSpec({
    required this.method,
    this.mount,
    this.role,
    this.jwt,
    this.jwtfile,
    this.roleid,
    this.secretid,
  });

  /// Printed without its credentials.
  ///
  /// A printer that walked every field would put the service-account JWT and
  /// the AppRole secret id into `print('bad chain: $specs')` - which is what
  /// someone writes when a chain will not build. Fields that hold a
  /// credential report whether they are set, never what they are.
  @override
  String toString() => 'AuthSpec(method: $method, mount: $mount, role: $role, '
      'jwtfile: $jwtfile, roleid: $roleid, jwt: ${setornot(jwt)}, '
      'secretid: ${setornot(secretid)})';
}

/// What a credential field reports about itself.
String setornot(String? value) =>
    (null != value && value.isNotEmpty) ? '[set]' : '[unset]';

/// The declarative form of a provider, as used in config and in the shared
/// spec. `kind` picks the provider; everything else is that kind's own.
class ProviderSpec {
  final String kind;

  /// The store name `Sekreto.getfrom` addresses. Defaults to `kind`.
  final String? name;
  final String? prefix;

  /// dotenv: the file to read. secretspec: the declaration to read.
  final String? file;

  /// memory: literal values, keyed like environment variables. Insertion
  /// ordered, because the spec compares whole maps.
  final Map<String, String>? values;

  /// file: the directory of one-secret-per-file entries.
  final String? dir;

  /// hashicorp / boru (wire) / gcp / 1password / doppler / infisical: the
  /// base URL.
  final String? addr;

  /// hashicorp / boru (wire) / gcp / azure / 1password / doppler /
  /// infisical: the token.
  final String? token;

  /// hashicorp / boru (wire): the KV mount (default `secret`).
  final String? mount;

  /// hashicorp: KV engine version, 1 or 2 (default 2).
  final int? kv;

  /// hashicorp: Vault Enterprise namespace (X-Vault-Namespace).
  final String? vaultnamespace;

  /// hashicorp: log in for a token instead of being handed one.
  final AuthSpec? auth;

  /// boru / secretspec: the executable to run (default: the kind's name).
  final String? command;

  /// secretspec: the profile to read (`--profile`).
  final String? profile;

  /// secretspec: which of ITS backends to read from (`--provider`), e.g.
  /// `keyring` or `dotenv://.env`. Named `backend` here because `provider`
  /// already means a sekreto provider.
  final String? backend;

  /// secretspec: the audit reason recorded for the read (`--reason`).
  /// SecretSpec refuses to read without one.
  final String? reason;

  /// boru: the namespace qualifying the alias.
  final String? namespace;

  /// boru: the vault home, passed as BORU_HOME.
  final String? home;

  /// aws: region and credentials; the standard AWS_* variables fill the
  /// rest.
  final String? region;
  final String? keyid;
  final String? secret;
  final String? session;

  /// gcp / doppler / infisical: the project, however that store names it.
  final String? project;

  /// azure: the Key Vault name or full URL. 1password: the vault name or id.
  final String? vault;

  /// azure: client-credential login. infisical: universal-auth login.
  final String? tenant;
  final String? clientid;
  final String? clientsecret;

  /// azure: where to log in / where IMDS answers. gcp: the metadata server.
  final String? loginaddr;
  final String? imdsaddr;
  final String? metadataaddr;

  /// azure: the Key Vault API version (default 7.4).
  final String? apiversion;

  /// doppler: the config slug (with `project`).
  final String? config;

  /// infisical: the environment slug and secret path.
  final String? environment;
  final String? path;

  const ProviderSpec({
    required this.kind,
    this.name,
    this.prefix,
    this.file,
    this.values,
    this.dir,
    this.addr,
    this.token,
    this.mount,
    this.kv,
    this.vaultnamespace,
    this.auth,
    this.command,
    this.profile,
    this.backend,
    this.reason,
    this.namespace,
    this.home,
    this.region,
    this.keyid,
    this.secret,
    this.session,
    this.project,
    this.vault,
    this.tenant,
    this.clientid,
    this.clientsecret,
    this.loginaddr,
    this.imdsaddr,
    this.metadataaddr,
    this.apiversion,
    this.config,
    this.environment,
    this.path,
  });

  /// Printed without its credentials. See AuthSpec.toString: a printer that
  /// walked every field would put the Vault token, the AWS secret access key
  /// and the Azure client secret into whatever formatted it.
  @override
  String toString() => 'ProviderSpec(kind: $kind, name: $name, addr: $addr, '
      'token: ${setornot(token)}, secret: ${setornot(secret)}, '
      'clientsecret: ${setornot(clientsecret)}, auth: $auth)';
}
