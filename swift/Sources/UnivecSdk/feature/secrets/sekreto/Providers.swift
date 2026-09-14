// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/src/Providers.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// What a provider is, what its declarative form looks like, how a provider
// kind becomes a voxgig/plugin definition - and the four BUILT-IN kinds.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or nil to mean "ask the next one". Nothing else about a
// provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.
//
// Two failure shapes, and they are never interchangeable. A store that
// does not hold the secret is a MISS (nil) - the chain carries on. A store
// that could not answer - bad credentials, unreachable host, missing
// configuration - is an ERROR: falling through there would quietly reach
// for a weaker store.
//
// THIS MODULE OPENS NO SOCKET, SIGNS NO REQUEST AND SPAWNS NO PROCESS.
// What makes a kind built in is that it reads at most a local file, and
// these four - env, memory, dotenv, file - are the floor every chain
// stands on. Every kind that needs a socket, a signature or a subprocess
// is a voxgig/plugin definition in the SekretoPlugins module, under
// plugins/ (docs/design/plugin-providers.md). `import Foundation` here is
// for files, paths and the process environment; URLSession and Process
// are on the other side of the module boundary and stay there.
//
// A port of typescript/src/provider/support.ts and
// typescript/src/provider/builtin.ts, which are canonical.

import Foundation

import VoxgigPlugin

// ------------------------------------------------------------ the specs


/// Logging in to a vault instead of being handed a token. `method` is
/// `kubernetes` or `approle`; `mount` defaults to the method name.
public struct AuthSpec: CustomStringConvertible {

  public var method: String
  public var mount: String?
  /// kubernetes: the Vault role to log in as.
  public var role: String?
  /// kubernetes: the service-account JWT itself (tests).
  public var jwt: String?
  /// kubernetes: where the JWT lives; the conventional pod path by default.
  public var jwtfile: String?
  /// approle: the role and secret ids.
  public var roleid: String?
  public var secretid: String?

  public init(
    method: String,
    mount: String? = nil,
    role: String? = nil,
    jwt: String? = nil,
    jwtfile: String? = nil,
    roleid: String? = nil,
    secretid: String? = nil
  ) {
    self.method = method
    self.mount = mount
    self.role = role
    self.jwt = jwt
    self.jwtfile = jwtfile
    self.roleid = roleid
    self.secretid = secretid
  }

  /// Printed without its credentials.
  ///
  /// A derived description prints every field, so
  /// `print("bad chain: \(specs)")` - which is what someone writes when a
  /// chain will not build - would put the service-account JWT and the
  /// AppRole secret id in the log. Fields that hold a credential report
  /// whether they are set, never what they are.
  public var description: String {
    return "AuthSpec(method=\(method), mount=\(shown(mount)), role=\(shown(role)), "
      + "jwtfile=\(shown(jwtfile)), roleid=\(shown(roleid)), "
      + "jwt=\(setornot(jwt)), secretid=\(setornot(secretid)))"
  }
}

/// What a credential field reports about itself.
public func setornot(_ value: String?) -> String {
  return (value?.isEmpty ?? true) ? "[unset]" : "[set]"
}

func shown(_ value: String?) -> String {
  return value ?? "nil"
}

/// The declarative form of a provider, as used in config and in the shared
/// spec. `kind` picks the provider; everything else is that kind's own.
public struct ProviderSpec: CustomStringConvertible {

  public var kind: String
  /// The store name `Sekreto.getfrom` addresses. Defaults to `kind`.
  public var name: String?
  public var prefix: String?
  /// dotenv: the file to read. secretspec: the declaration to read.
  public var file: String?
  /// memory: literal values, keyed like environment variables.
  public var values: Ordered<String>?
  /// file: the directory of one-secret-per-file entries.
  public var dir: String?
  /// hashicorp / boru (wire) / gcp / 1password / doppler / infisical: the base URL.
  public var addr: String?
  /// hashicorp / boru (wire) / gcp / azure / 1password / doppler / infisical: the token.
  public var token: String?
  /// hashicorp / boru (wire): the KV mount (default `secret`).
  public var mount: String?
  /// hashicorp: KV engine version, 1 or 2 (default 2).
  public var kv: Int?
  /// hashicorp: Vault Enterprise namespace (X-Vault-Namespace).
  public var vaultnamespace: String?
  /// hashicorp: log in for a token instead of being handed one.
  public var auth: AuthSpec?
  /// boru / secretspec: the executable to run (default: the kind's own name).
  public var command: String?
  /// secretspec: the profile to read (`--profile`).
  public var profile: String?
  /// secretspec: which of ITS backends to read from (`--provider`), e.g.
  /// `keyring` or `dotenv://.env`. Named `backend` here because `provider`
  /// already means a sekreto provider.
  public var backend: String?
  /// secretspec: the audit reason recorded for the read (`--reason`).
  public var reason: String?
  /// boru: the namespace qualifying the alias.
  public var namespace: String?
  /// boru: the vault home, passed as BORU_HOME.
  public var home: String?
  /// aws: region and credentials; the standard AWS_* variables fill the rest.
  public var region: String?
  public var keyid: String?
  public var secret: String?
  public var session: String?
  /// gcp / doppler / infisical: the project, however that store names it.
  public var project: String?
  /// azure: the Key Vault name or full URL. 1password: the vault name or id.
  public var vault: String?
  /// azure: client-credential login. infisical: universal-auth login.
  public var tenant: String?
  public var clientid: String?
  public var clientsecret: String?
  /// azure: where to log in / where IMDS answers. gcp: the metadata server.
  public var loginaddr: String?
  public var imdsaddr: String?
  public var metadataaddr: String?
  /// azure: the Key Vault API version (default 7.4).
  public var apiversion: String?
  /// doppler: the config slug (with `project`).
  public var config: String?
  /// infisical: the environment slug and secret path.
  public var environment: String?
  public var path: String?

  public init(
    kind: String,
    name: String? = nil,
    prefix: String? = nil,
    file: String? = nil,
    values: Ordered<String>? = nil,
    dir: String? = nil,
    addr: String? = nil,
    token: String? = nil,
    mount: String? = nil,
    kv: Int? = nil,
    vaultnamespace: String? = nil,
    auth: AuthSpec? = nil,
    command: String? = nil,
    profile: String? = nil,
    backend: String? = nil,
    reason: String? = nil,
    namespace: String? = nil,
    home: String? = nil,
    region: String? = nil,
    keyid: String? = nil,
    secret: String? = nil,
    session: String? = nil,
    project: String? = nil,
    vault: String? = nil,
    tenant: String? = nil,
    clientid: String? = nil,
    clientsecret: String? = nil,
    loginaddr: String? = nil,
    imdsaddr: String? = nil,
    metadataaddr: String? = nil,
    apiversion: String? = nil,
    config: String? = nil,
    environment: String? = nil,
    path: String? = nil
  ) {
    self.kind = kind
    self.name = name
    self.prefix = prefix
    self.file = file
    self.values = values
    self.dir = dir
    self.addr = addr
    self.token = token
    self.mount = mount
    self.kv = kv
    self.vaultnamespace = vaultnamespace
    self.auth = auth
    self.command = command
    self.profile = profile
    self.backend = backend
    self.reason = reason
    self.namespace = namespace
    self.home = home
    self.region = region
    self.keyid = keyid
    self.secret = secret
    self.session = session
    self.project = project
    self.vault = vault
    self.tenant = tenant
    self.clientid = clientid
    self.clientsecret = clientsecret
    self.loginaddr = loginaddr
    self.imdsaddr = imdsaddr
    self.metadataaddr = metadataaddr
    self.apiversion = apiversion
    self.config = config
    self.environment = environment
    self.path = path
  }

  /// Printed without its credentials. See AuthSpec.description: a derived
  /// one would put the Vault token, the AWS secret access key and the
  /// Azure client secret into whatever formatted it.
  public var description: String {
    return "ProviderSpec(kind=\(kind), name=\(shown(name)), addr=\(shown(addr)), "
      + "token=\(setornot(token)), secret=\(setornot(secret)), "
      + "clientsecret=\(setornot(clientsecret)), "
      + "auth=\(nil == auth ? "nil" : auth!.description))"
  }
}

// ------------------------------------------------------- shared machinery

/// An environment variable, or nil.
func getenv(_ name: String) -> String? {
  return ProcessInfo.processInfo.environment[name]
}

/// The first candidate that is set and non-empty, or empty.
public func first(_ candidates: String?...) -> String {
  for candidate in candidates {
    if let value = candidate, !value.isEmpty { return value }
  }
  return ""
}

/// What an error has to say for itself, never the empty string.
///
/// PUBLIC because the plugins need it too and cannot see an internal
/// helper across the module boundary: this is the one shared error-text
/// rule, and two copies of it would answer differently the day one is
/// fixed.
public func why(_ err: Error) -> String {
  let text = (err as NSError).localizedDescription

  if !text.isEmpty && "(null)" != text { return text }

  return String(describing: err)
}

// ------------------------------------------------------------ file reads

/// The outcome of reading a file that may legitimately not be there.
public enum Readout {
  /// The bytes, as text.
  case text(String)
  /// No such file, or no such directory: "no secrets here", a MISS.
  case absent
  /// The file is there and could not be read: an ERROR.
  case failed(String)
}

/// Read a whole file.
///
/// Absence is a MISS and the chain carries on; anything else - permission
/// denied, an unreadable mount, a failing disk - is an ERROR, because
/// returning a miss there falls silently through to a weaker store.
///
/// The obvious spelling, `FileManager.fileExists`, is wrong in exactly the
/// case the rule exists for: it answers false for a directory the process
/// may not stat, and would turn a locked mount - the canonical "unreadable
/// mount" - into a miss. The read is attempted, and only a not-found
/// answer is read as absence.
public func readfile(_ path: String) -> Readout {
  do {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return .text(String(decoding: data, as: UTF8.self))
  } catch {
    let err = error as NSError

    if NSCocoaErrorDomain == err.domain && NSFileReadNoSuchFileError == err.code {
      return .absent
    }

    // A path whose parent is a plain file, or is not there at all, really
    // is "no secrets here" - the ENOTDIR case, which not every platform
    // reports as a not-found error.
    let parent = (path as NSString).deletingLastPathComponent
    if !parent.isEmpty {
      var isdir: ObjCBool = false
      if !FileManager.default.fileExists(atPath: parent, isDirectory: &isdir) || !isdir.boolValue {
        return .absent
      }
    }

    return .failed(why(error))
  }
}

// ------------------------------------------------------------- built in

/// Environment variables: `api.token` from `API_TOKEN`.
public final class EnvProvider: Provider {

  private let prefix: String?
  private let source: Ordered<String>?

  public init(prefix: String? = nil, source: Ordered<String>? = nil) {
    self.prefix = prefix
    self.source = source
  }

  public func lookup(_ name: String) throws -> String? {
    let key = try envkey(name, prefix)

    if let source = source { return source[key] }

    return getenv(key)
  }

  public func describe() -> String {
    let use = prefix ?? ""
    return use.isEmpty ? "env" : "env:\(use)"
  }
}

/// A `.env` file, read once, keyed exactly like the environment.
///
/// Loaded LAZILY: a chain may hold a dotenv provider and never be asked
/// anything, and an eager constructor would read whatever `.env` happens
/// to sit in the working directory.
public final class DotenvProvider: Provider {

  private let file: String
  private let prefix: String?
  private var values: Ordered<String>?

  public init(file: String, prefix: String? = nil) {
    self.file = file
    self.prefix = prefix
  }

  private func load() throws -> Ordered<String> {
    if let loaded = values { return loaded }

    var loaded = Ordered<String>()

    switch readfile(file) {
    case .text(let body):
      loaded = parsedotenv(body)
    // An absent file - or an absent directory - means "no secrets here",
    // exactly like the file provider.
    case .absent:
      loaded = Ordered<String>()
    case .failed(let err):
      throw SekretoError("sekreto: dotenv provider cannot read \(file): \(err)")
    }

    values = loaded
    return loaded
  }

  public func lookup(_ name: String) throws -> String? {
    return try load()[try envkey(name, prefix)]
  }

  public func describe() -> String {
    return "dotenv:\(file)"
  }
}

/// Literal values, keyed like environment variables. The spec uses this to
/// test chain behaviour without touching the outside world.
public final class MemoryProvider: Provider {

  private let values: Ordered<String>
  private let prefix: String?

  public init(values: Ordered<String>? = nil, prefix: String? = nil) {
    self.values = values ?? Ordered<String>()
    self.prefix = prefix
  }

  public func lookup(_ name: String) throws -> String? {
    return values[try envkey(name, prefix)]
  }

  public func describe() -> String {
    let use = prefix ?? ""
    return use.isEmpty ? "memory" : "memory:\(use)"
  }
}

/// A directory of one-secret-per-file entries, keyed like the environment:
/// `api.token` reads `<dir>/API_TOKEN`.
///
/// This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
/// secret, and a systemd credentials directory, so those all work with no
/// further configuration. One trailing newline is stripped - tools that
/// write these files disagree about it, and a newline is never part of a
/// secret on purpose.
public final class FileProvider: Provider {

  private let dir: String
  private let prefix: String?

  public init(dir: String, prefix: String? = nil) {
    self.dir = dir
    self.prefix = prefix
  }

  public func lookup(_ name: String) throws -> String? {
    let key = try envkey(name, prefix)
    let path = dir.isEmpty ? key : (dir as NSString).appendingPathComponent(key)

    switch readfile(path) {
    case .absent:
      return nil
    case .failed(let err):
      throw SekretoError("sekreto: file provider cannot read \(path): \(err)")
    case .text(let body):
      if body.hasSuffix("\r\n") { return String(body.dropLast(2)) }
      if body.hasSuffix("\n") { return String(body.dropLast()) }
      return body
    }
  }

  public func describe() -> String {
    return "file:\(dir)"
  }
}

// --------------------------------------- providers as plugin definitions

/// The export key under which a provider definition publishes the provider
/// it built. `Sekreto` reads `<ref>/provider` off the host.
public let PROVIDER_EXPORT = "provider"

/// The voxgig/plugin error code a SekretoError travels under when it is
/// thrown inside a definition's `define`.
///
/// plugin wraps a code-less error thrown by a callback as
/// `plugin_define_failed`, and keeps an error that already carries a code.
/// A provider that refuses its own configuration - `kv: 3`, a missing
/// project - throws a SekretoError, and the shared spec pins that message
/// byte for byte, so it must come back out of the host exactly as it went
/// in. `providerplugin` puts this code on; `Sekreto` takes it off. Nowhere
/// else catches and rewraps.
public let ERROR_CODE = "sekreto_error"

/// A provider kind, as a voxgig/plugin definition.
///
/// This is the whole bridge between the two libraries. The definition's
/// `name` is the `kind` a ProviderSpec names; its `define` reads the spec
/// back off the instance's options, builds the provider with `make`, and
/// exports it. Nothing runs at `activate`: a provider opens nothing until
/// its first lookup, so there is nothing to capture - a provider that does
/// hold a resource acquires it there and lets the instance scope unwind
/// it.
///
/// Every built-in and every plugin is made this way, so a custom provider
/// kind is one call:
///
///     providerplugin("mystore") { spec in mystoreprovider(spec.addr) }
///
/// The provider crosses as `Value.opaque` - plugin's own escape hatch for
/// "a client the library never inspects". The value model carries JSON,
/// and a Provider is not JSON. `Provider` is `AnyObject`-constrained
/// precisely so that it fits.
public func providerplugin(
  _ kind: String,
  _ make: @escaping (ProviderSpec) throws -> Provider
) -> Definition {
  return Definition(
    name: kind,
    define: { inst in
      let provider: Provider

      do {
        provider = try make(specof(inst.options))
      } catch let err as SekretoError {
        // The message is the spec's, byte for byte. `cause` is where
        // `Sekreto` reads it back from.
        throw PluginError(
          ERROR_CODE, err.message,
          ["ref": .str(inst.ref), "cause": .str(err.message)])
      }

      inst.export(PROVIDER_EXPORT, .opaque(provider))
    })
}

/// A ProviderSpec as the options map a plugin instance is declared with.
///
/// Every field goes through, so that `host.list()` and a configuration
/// document describe the same instance the chain holds. Absent stays
/// absent: an omitted key and an authored empty string are not the same
/// thing to a provider that defaults on emptiness.
public func optionsof(_ spec: ProviderSpec) -> Value {
  var out: [String: Value] = ["kind": .str(spec.kind)]

  func put(_ key: String, _ value: String?) {
    if let value = value { out[key] = .str(value) }
  }

  put("name", spec.name)
  put("prefix", spec.prefix)
  put("file", spec.file)
  put("dir", spec.dir)
  put("addr", spec.addr)
  put("token", spec.token)
  put("mount", spec.mount)
  put("vaultnamespace", spec.vaultnamespace)
  put("command", spec.command)
  put("profile", spec.profile)
  put("backend", spec.backend)
  put("reason", spec.reason)
  put("namespace", spec.namespace)
  put("home", spec.home)
  put("region", spec.region)
  put("keyid", spec.keyid)
  put("secret", spec.secret)
  put("session", spec.session)
  put("project", spec.project)
  put("vault", spec.vault)
  put("tenant", spec.tenant)
  put("clientid", spec.clientid)
  put("clientsecret", spec.clientsecret)
  put("loginaddr", spec.loginaddr)
  put("imdsaddr", spec.imdsaddr)
  put("metadataaddr", spec.metadataaddr)
  put("apiversion", spec.apiversion)
  put("config", spec.config)
  put("environment", spec.environment)
  put("path", spec.path)

  if let kv = spec.kv {
    out["kv"] = .num(Double(kv))
  }

  if let values = spec.values {
    var entries: [String: Value] = [:]
    for (key, value) in values.pairs { entries[key] = .str(value) }
    out["values"] = .map(entries)
  }

  if let auth = spec.auth {
    var entries: [String: Value] = ["method": .str(auth.method)]
    func putauth(_ key: String, _ value: String?) {
      if let value = value { entries[key] = .str(value) }
    }
    putauth("mount", auth.mount)
    putauth("role", auth.role)
    putauth("jwt", auth.jwt)
    putauth("jwtfile", auth.jwtfile)
    putauth("roleid", auth.roleid)
    putauth("secretid", auth.secretid)
    out["auth"] = .map(entries)
  }

  return .map(out)
}

/// A ProviderSpec read back off a plugin instance's options - the shape
/// `optionsof` produced, and the shape a configuration document would.
public func specof(_ options: Value) -> ProviderSpec {
  func text(_ key: String) -> String? {
    return options.get(key)?.asString
  }

  var values: Ordered<String>? = nil

  if let entries = options.get("values"), entries.isMap {
    var out = Ordered<String>()
    // `keys` is sorted: a swift Dictionary has no order at all, and a
    // memory provider is a lookup by key, so sorted is the only order
    // that is the same on two runs.
    for key in entries.keys { out[key] = entries.at(key).asString ?? "" }
    values = out
  }

  var auth: AuthSpec? = nil

  if let entries = options.get("auth"), entries.isMap {
    auth = AuthSpec(
      method: entries.at("method").asString ?? "",
      mount: entries.get("mount")?.asString,
      role: entries.get("role")?.asString,
      jwt: entries.get("jwt")?.asString,
      jwtfile: entries.get("jwtfile")?.asString,
      roleid: entries.get("roleid")?.asString,
      secretid: entries.get("secretid")?.asString
    )
  }

  return ProviderSpec(
    kind: text("kind") ?? "",
    name: text("name"),
    prefix: text("prefix"),
    file: text("file"),
    values: values,
    dir: text("dir"),
    addr: text("addr"),
    token: text("token"),
    mount: text("mount"),
    kv: options.get("kv")?.asInt,
    vaultnamespace: text("vaultnamespace"),
    auth: auth,
    command: text("command"),
    profile: text("profile"),
    backend: text("backend"),
    reason: text("reason"),
    namespace: text("namespace"),
    home: text("home"),
    region: text("region"),
    keyid: text("keyid"),
    secret: text("secret"),
    session: text("session"),
    project: text("project"),
    vault: text("vault"),
    tenant: text("tenant"),
    clientid: text("clientid"),
    clientsecret: text("clientsecret"),
    loginaddr: text("loginaddr"),
    imdsaddr: text("imdsaddr"),
    metadataaddr: text("metadataaddr"),
    apiversion: text("apiversion"),
    config: text("config"),
    environment: text("environment"),
    path: text("path")
  )
}

/// THE BUILT-IN PROVIDER KINDS - the same four in every port.
///
/// What makes a kind built in is that it needs nothing of the platform
/// beyond reading a local file: no socket, no TLS, no crypto, no child
/// process. These four are the floor every chain stands on, and a chain
/// that reads secrets from options, the environment, a plaintext `.env`
/// and a mounted secret directory works with no plugin loaded at all.
/// Everything else - the vault clients, the cloud stores, the CLIs - is a
/// plugin, and lives under plugins/ (docs/design/plugin-providers.md).
///
/// `Sekreto` puts these in every catalog ahead of the plugins it is
/// handed, so a plugin naming one of these four replaces it.
public let BUILTINS: [Definition] = [
  providerplugin("env") { spec in EnvProvider(prefix: spec.prefix) },
  providerplugin("memory") { spec in
    MemoryProvider(values: spec.values, prefix: spec.prefix)
  },
  providerplugin("dotenv") { spec in
    DotenvProvider(file: first(spec.file, ".env"), prefix: spec.prefix)
  },
  providerplugin("file") { spec in FileProvider(dir: spec.dir ?? "", prefix: spec.prefix) },
]

/// Every kind this library ships, built in or as a plugin, so that an
/// unknown kind can be told from a plugin that was not passed in.
///
/// The core names the KINDS, which are spec, and links none of the code
/// that implements the ten: a list of strings reaches nothing.
public enum KINDS {
  public static let builtin = ["env", "memory", "dotenv", "file"]
  public static let plugin = [
    "hashicorp", "boru", "awssecrets", "awsparams", "gcpsecrets",
    "azuresecrets", "onepassword", "doppler", "infisical", "secretspec",
  ]
}
