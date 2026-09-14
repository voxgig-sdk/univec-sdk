// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (rust/src/providers.rs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! What a provider is, what its declarative form looks like, how a
//! provider kind becomes a voxgig/plugin definition - and the four
//! BUILT-IN kinds.
//!
//! A provider answers one question: "do you have this secret?" It returns
//! the value, or None to mean "ask the next one". Nothing else about a
//! provider is visible to the caller - which is the point: an app reads
//! `api.token` and never learns whether it came from the environment, a
//! .env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.
//!
//! Two failure shapes, and they are never interchangeable. A store that
//! does not hold the secret is a MISS (None) - the chain carries on. A
//! store that could not answer - bad credentials, unreachable host,
//! missing configuration - is an ERROR: falling through there would
//! quietly reach for a weaker store.
//!
//! THIS CRATE LINKS NO TLS, NO SOCKET AND NO SUBPROCESS. What makes a
//! kind built in is that it needs nothing of the platform beyond reading
//! a local file; every kind that opens a socket, signs a request or
//! spawns a process is a plugin in its own crate under `plugins/`, linked
//! only by a binary that names it (docs/design/plugin-providers.md).
//!
//! A port of typescript/src/provider/support.ts and
//! typescript/src/provider/builtin.ts, which are canonical.

use std::collections::BTreeMap;
use std::env;
use std::fmt;
use std::fs;
use std::io;
use std::path::Path;
use std::rc::Rc;

use super::super::plugin::catalog::Definition;
use super::super::plugin::host::Inst;
use super::super::plugin::types::{details, PluginError};
use super::super::plugin::value::Value;

use super::sekreto::{envkey, Answer, SekretoError};

/// A source of secrets.
pub trait Provider {
    /// The value, or None if this provider does not have it.
    fn lookup(&self, name: &str) -> Answer<Option<String>>;

    /// A short description, shown by `Sekreto::sources`.
    fn describe(&self) -> String;
}

/// hashicorp: log in for a token instead of being handed one.
///
/// No `Debug` derive: `secretid` and `jwt` are credentials, and
/// `tracing::error!(?spec, ...)` is the idiomatic thing to write. See the
/// hand-written impl below.
#[derive(Clone, Default)]
pub struct AuthSpec {
    /// `kubernetes` or `approle`.
    pub method: String,
    /// The auth mount, defaulting to the method name.
    pub mount: String,
    /// kubernetes: the Vault role to log in as.
    pub role: String,
    /// kubernetes: the service-account JWT itself (tests); None means the
    /// jwt file is read instead.
    pub jwt: Option<String>,
    /// kubernetes: where the JWT lives; the conventional pod path by
    /// default.
    pub jwtfile: String,
    /// approle: the role and secret ids.
    pub roleid: String,
    pub secretid: String,
}

/// The declarative form of a provider, as used in config and in the shared
/// spec. Absent fields are empty strings (or zero, or None).
///
/// No `Debug` derive: `token`, `secret` and `clientsecret` are credentials.
/// See the hand-written impl below.
#[derive(Clone, Default)]
pub struct ProviderSpec {
    pub kind: String,
    /// The store name `Sekreto::getfrom` addresses. Defaults to `kind`.
    pub name: String,
    pub prefix: String,
    /// dotenv: the file to read.
    pub file: String,
    /// memory: literal values, keyed like environment variables.
    pub values: BTreeMap<String, String>,
    /// file: the directory of one-secret-per-file entries.
    pub dir: String,
    /// hashicorp / boru (wire) / gcp / 1password / doppler / infisical:
    /// the base URL.
    pub addr: String,
    /// hashicorp / boru (wire) / gcp / azure / 1password / doppler /
    /// infisical: the access token.
    pub token: String,
    /// hashicorp / boru (wire): the KV mount (default `secret`).
    pub mount: String,
    /// hashicorp: KV engine version, 1 or 2 (0 means the default, 2).
    pub kv: u32,
    /// hashicorp: Vault Enterprise namespace (X-Vault-Namespace).
    pub vaultnamespace: String,
    /// hashicorp: log in for a token instead of being handed one.
    pub auth: Option<AuthSpec>,
    /// boru / secretspec: the executable to run (default: the kind's own
    /// name).
    pub command: String,
    /// boru: the namespace qualifying the alias.
    pub namespace: String,
    /// boru: the vault home, passed as BORU_HOME.
    pub home: String,
    /// secretspec: the profile to read (`--profile`).
    pub profile: String,
    /// secretspec: which of ITS backends to read from (`--provider`),
    /// e.g. `keyring` or `dotenv://.env`. Named `backend` because
    /// `provider` already means a sekreto provider.
    pub backend: String,
    /// secretspec: the audit reason recorded for the read (`--reason`).
    /// SecretSpec refuses to read without one.
    pub reason: String,
    /// aws: region and credentials; the standard AWS_* environment
    /// variables fill whichever are not given.
    pub region: String,
    pub keyid: String,
    pub secret: String,
    pub session: String,
    /// gcp / doppler / infisical: the project (GCP project id, Doppler
    /// project slug, Infisical workspace id).
    pub project: String,
    /// azure: the Key Vault name or full URL. 1password: the vault name
    /// or id.
    pub vault: String,
    /// azure: client-credential login. infisical: universal-auth login
    /// (tenant is Azure-only).
    pub tenant: String,
    pub clientid: String,
    pub clientsecret: String,
    /// azure: where to log in / where IMDS answers. gcp: where the
    /// metadata server answers. Overridable for tests and for clouds with
    /// nonstandard endpoints.
    pub loginaddr: String,
    pub imdsaddr: String,
    pub metadataaddr: String,
    /// azure: the Key Vault API version (default 7.4).
    pub apiversion: String,
    /// doppler: the config slug (with `project`).
    pub config: String,
    /// infisical: the environment slug and secret path.
    pub environment: String,
    pub path: String,

    /// A provider already built, joining the chain as it is - `kind`
    /// empty. This is how a custom provider that is not a plugin gets in.
    /// Never serialized: a live provider is not data.
    pub provider: Option<Rc<dyn Provider>>,
}

impl ProviderSpec {
    pub fn of(kind: &str) -> Self {
        ProviderSpec {
            kind: kind.to_string(),
            ..Default::default()
        }
    }
}


/// Environment variables: `api.token` from `API_TOKEN`.
pub struct EnvProvider {
    pub prefix: String,
}

impl Provider for EnvProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        Ok(env::var(envkey(name, &self.prefix)?).ok())
    }

    fn describe(&self) -> String {
        if self.prefix.is_empty() {
            "env".to_string()
        } else {
            format!("env:{}", self.prefix)
        }
    }
}

/// A `.env` file, read once, keyed exactly like the environment.
pub struct DotenvProvider {
    pub file: String,
    pub prefix: String,
    values: BTreeMap<String, String>,
    // A read failure other than "file not found", kept for lookup to
    // raise: construction stays infallible, but the failure must not be
    // swallowed as "no secrets here".
    fail: Option<SekretoError>,
}

impl DotenvProvider {
    pub fn new(file: &str, prefix: &str) -> Self {
        // An absent file - or an absent directory - means "no secrets
        // here", exactly like FileProvider. Anything else (permission
        // denied, an unreadable mount) is a store that could not answer,
        // and swallowing it would fall through to a weaker store.
        let (values, fail) = match fs::read_to_string(file) {
            Ok(text) => (super::sekreto::parsedotenv(&text), None),
            Err(err) => {
                if matches!(
                    err.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
                ) {
                    (BTreeMap::new(), None)
                } else {
                    (
                        BTreeMap::new(),
                        Some(SekretoError::new(format!(
                            "sekreto: dotenv provider cannot read {}: {}",
                            file, err
                        ))),
                    )
                }
            }
        };

        DotenvProvider {
            file: file.to_string(),
            prefix: prefix.to_string(),
            values,
            fail,
        }
    }
}

impl Provider for DotenvProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        if let Some(fail) = &self.fail {
            return Err(fail.clone());
        }
        Ok(self.values.get(&envkey(name, &self.prefix)?).cloned())
    }

    fn describe(&self) -> String {
        format!("dotenv:{}", self.file)
    }
}

/// Literal values, keyed like environment variables. The spec uses this to
/// test chain behaviour without touching the outside world.
pub struct MemoryProvider {
    pub values: BTreeMap<String, String>,
    pub prefix: String,
}

impl Provider for MemoryProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        Ok(self.values.get(&envkey(name, &self.prefix)?).cloned())
    }

    fn describe(&self) -> String {
        if self.prefix.is_empty() {
            "memory".to_string()
        } else {
            format!("memory:{}", self.prefix)
        }
    }
}

/// A directory of one-secret-per-file entries, keyed like the
/// environment: `api.token` reads `<dir>/API_TOKEN`.
///
/// This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
/// secret, and a systemd credentials directory, so those all work with no
/// further configuration. One trailing newline is stripped - tools that
/// write these files disagree about it, and a newline is never part of a
/// secret on purpose.
pub struct FileProvider {
    pub dir: String,
    pub prefix: String,
}

impl Provider for FileProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        let file = Path::new(&self.dir).join(envkey(name, &self.prefix)?);

        let text = match fs::read_to_string(&file) {
            Ok(text) => text,
            Err(err) => {
                // An absent file - or an absent directory - means "no
                // secrets here", exactly like a missing .env. Anything else
                // (permission denied, an unreadable mount) is a store that
                // could not answer.
                if matches!(
                    err.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
                ) {
                    return Ok(None);
                }
                return Err(SekretoError::new(format!(
                    "sekreto: file provider cannot read {}: {}",
                    file.display(),
                    err
                )));
            }
        };

        let text = match text.strip_suffix('\n') {
            Some(rest) => rest.strip_suffix('\r').unwrap_or(rest),
            None => &text,
        };

        Ok(Some(text.to_string()))
    }

    fn describe(&self) -> String {
        format!("file:{}", self.dir)
    }
}

/// Printed without its credentials.
///
/// A derived `Debug` puts the Vault token, the AWS secret access key and
/// the Azure client secret into whatever formatted it - and
/// `tracing::error!(?spec, "chain build failed")` is exactly what someone
/// writes when a chain will not build. Fields that hold a credential
/// report whether they are set, never what they are.
impl fmt::Debug for AuthSpec {
    fn fmt(&self, form: &mut fmt::Formatter<'_>) -> fmt::Result {
        form.debug_struct("AuthSpec")
            .field("method", &self.method)
            .field("mount", &self.mount)
            .field("role", &self.role)
            .field("jwtfile", &self.jwtfile)
            .field("roleid", &self.roleid)
            .field("jwt", &setornot(self.jwt.as_deref().unwrap_or("")))
            .field("secretid", &setornot(&self.secretid))
            .finish()
    }
}

impl fmt::Debug for ProviderSpec {
    fn fmt(&self, form: &mut fmt::Formatter<'_>) -> fmt::Result {
        form.debug_struct("ProviderSpec")
            .field("kind", &self.kind)
            .field("name", &self.name)
            .field("addr", &self.addr)
            .field("token", &setornot(&self.token))
            .field("secret", &setornot(&self.secret))
            .field("clientsecret", &setornot(&self.clientsecret))
            .field("auth", &self.auth)
            .finish_non_exhaustive()
    }
}

/// What a credential field reports about itself.
fn setornot(value: &str) -> &'static str {
    if value.is_empty() {
        "[unset]"
    } else {
        "[set]"
    }
}
// --- providers as voxgig/plugin definitions ----------------------------

/// The export key under which a provider definition publishes the
/// provider it built. `Sekreto::new` reads `<ref>/provider` off the host.
pub const PROVIDER_EXPORT: &str = "provider";

/// The voxgig/plugin error code a `SekretoError` travels under when a
/// definition's `define` refuses.
///
/// plugin wraps a code-less error raised by a callback as
/// `plugin_define_failed`, and keeps one that already carries a code. A
/// provider that refuses its own configuration - `kv: 3`, a missing
/// project - returns a `SekretoError`, and that message is pinned by the
/// spec byte for byte, so it must come back out of the host exactly as it
/// went in. `providerplugin` puts this code on; `Sekreto::new` takes it
/// off. Nowhere else catches and rewraps.
pub const ERROR_CODE: &str = "sekreto_error";

/// A provider kind, as a voxgig/plugin definition.
///
/// This is the whole bridge between the two libraries. The definition's
/// name is the `kind` a `ProviderSpec` names; its `define` reads the spec
/// back off the instance's options, builds the provider with `make`, and
/// exports it. Nothing runs at activate: a provider opens nothing until
/// its first `lookup`, so there is nothing to capture - a provider that
/// does hold a resource acquires it there and lets the instance scope
/// unwind it.
///
/// Every built-in and every plugin is made this way, so a custom provider
/// kind is one call:
///
/// ```ignore
/// providerplugin("mystore", |spec| {
///     Ok(Rc::new(MyStore { addr: spec.addr.clone() }) as Rc<dyn Provider>)
/// })
/// ```
///
/// The provider crosses the boundary as `Value::Opaque` - plugin's own
/// escape hatch for "a client the library never inspects" (§11). The
/// value model carries JSON, and a `Provider` is not JSON.
pub fn providerplugin<F>(kind: &str, make: F) -> Definition
where
    F: Fn(&ProviderSpec) -> Answer<Rc<dyn Provider>> + 'static,
{
    let mut definition = Definition::named(kind);

    definition.define = Some(Rc::new(move |inst: &Inst| {
        let spec = specof(&inst.options());

        match make(&spec) {
            Ok(provider) => {
                inst.export(PROVIDER_EXPORT, Value::Opaque(Rc::new(provider)));
                Ok(())
            }
            // The message is the spec's, byte for byte. `cause` is where
            // `Sekreto::new` reads it back from.
            Err(err) => Err(PluginError::new(
                ERROR_CODE,
                &err.message,
                details(&[
                    ("ref", Value::str(&inst.eref)),
                    ("cause", Value::str(&err.message)),
                ]),
            )),
        }
    }));

    definition
}

/// A `ProviderSpec` read back off a plugin instance's options map - the
/// shape `optionsof` produced, and the shape a config document would.
pub fn specof(options: &Value) -> ProviderSpec {
    let mut values = BTreeMap::new();
    if let Some(entries) = options.get("values").as_map() {
        for (key, entry) in entries {
            values.insert(key.clone(), entry.as_str().unwrap_or("").to_string());
        }
    }

    let auth = options.get("auth");

    ProviderSpec {
        kind: gettext(options, "kind"),
        name: gettext(options, "name"),
        prefix: gettext(options, "prefix"),
        file: gettext(options, "file"),
        values,
        dir: gettext(options, "dir"),
        addr: gettext(options, "addr"),
        token: gettext(options, "token"),
        mount: gettext(options, "mount"),
        kv: options.get("kv").as_int().unwrap_or(0) as u32,
        vaultnamespace: gettext(options, "vaultnamespace"),
        auth: if auth.is_null() {
            None
        } else {
            Some(AuthSpec {
                method: gettext(&auth, "method"),
                mount: gettext(&auth, "mount"),
                role: gettext(&auth, "role"),
                jwt: if auth.has("jwt") {
                    Some(gettext(&auth, "jwt"))
                } else {
                    None
                },
                jwtfile: gettext(&auth, "jwtfile"),
                roleid: gettext(&auth, "roleid"),
                secretid: gettext(&auth, "secretid"),
            })
        },
        command: gettext(options, "command"),
        namespace: gettext(options, "namespace"),
        home: gettext(options, "home"),
        profile: gettext(options, "profile"),
        backend: gettext(options, "backend"),
        reason: gettext(options, "reason"),
        region: gettext(options, "region"),
        keyid: gettext(options, "keyid"),
        secret: gettext(options, "secret"),
        session: gettext(options, "session"),
        project: gettext(options, "project"),
        vault: gettext(options, "vault"),
        tenant: gettext(options, "tenant"),
        clientid: gettext(options, "clientid"),
        clientsecret: gettext(options, "clientsecret"),
        loginaddr: gettext(options, "loginaddr"),
        imdsaddr: gettext(options, "imdsaddr"),
        metadataaddr: gettext(options, "metadataaddr"),
        apiversion: gettext(options, "apiversion"),
        config: gettext(options, "config"),
        environment: gettext(options, "environment"),
        path: gettext(options, "path"),
        provider: None,
    }
}

/// A `ProviderSpec` as a plugin instance's options map.
///
/// Only the keys actually set are written, so `host.list()` and a
/// declaration document read like the configuration someone wrote rather
/// than like the struct.
pub fn optionsof(spec: &ProviderSpec) -> Value {
    let mut out = Value::map();

    puttext(&mut out, "kind", &spec.kind);
    puttext(&mut out, "name", &spec.name);
    puttext(&mut out, "prefix", &spec.prefix);
    puttext(&mut out, "file", &spec.file);

    if !spec.values.is_empty() {
        let mut values = Value::map();
        for (key, value) in &spec.values {
            values.set(key, Value::str(value));
        }
        out.set("values", values);
    }

    puttext(&mut out, "dir", &spec.dir);
    puttext(&mut out, "addr", &spec.addr);
    puttext(&mut out, "token", &spec.token);
    puttext(&mut out, "mount", &spec.mount);

    if 0 != spec.kv {
        out.set("kv", Value::Num(spec.kv as f64));
    }

    puttext(&mut out, "vaultnamespace", &spec.vaultnamespace);

    if let Some(auth) = &spec.auth {
        let mut entry = Value::map();
        puttext(&mut entry, "method", &auth.method);
        puttext(&mut entry, "mount", &auth.mount);
        puttext(&mut entry, "role", &auth.role);
        if let Some(jwt) = &auth.jwt {
            entry.set("jwt", Value::str(jwt));
        }
        puttext(&mut entry, "jwtfile", &auth.jwtfile);
        puttext(&mut entry, "roleid", &auth.roleid);
        puttext(&mut entry, "secretid", &auth.secretid);
        out.set("auth", entry);
    }

    puttext(&mut out, "command", &spec.command);
    puttext(&mut out, "namespace", &spec.namespace);
    puttext(&mut out, "home", &spec.home);
    puttext(&mut out, "profile", &spec.profile);
    puttext(&mut out, "backend", &spec.backend);
    puttext(&mut out, "reason", &spec.reason);
    puttext(&mut out, "region", &spec.region);
    puttext(&mut out, "keyid", &spec.keyid);
    puttext(&mut out, "secret", &spec.secret);
    puttext(&mut out, "session", &spec.session);
    puttext(&mut out, "project", &spec.project);
    puttext(&mut out, "vault", &spec.vault);
    puttext(&mut out, "tenant", &spec.tenant);
    puttext(&mut out, "clientid", &spec.clientid);
    puttext(&mut out, "clientsecret", &spec.clientsecret);
    puttext(&mut out, "loginaddr", &spec.loginaddr);
    puttext(&mut out, "imdsaddr", &spec.imdsaddr);
    puttext(&mut out, "metadataaddr", &spec.metadataaddr);
    puttext(&mut out, "apiversion", &spec.apiversion);
    puttext(&mut out, "config", &spec.config);
    puttext(&mut out, "environment", &spec.environment);
    puttext(&mut out, "path", &spec.path);

    out
}

fn puttext(out: &mut Value, key: &str, value: &str) {
    if !value.is_empty() {
        out.set(key, Value::str(value));
    }
}

fn gettext(value: &Value, key: &str) -> String {
    value.get(key).as_str().unwrap_or("").to_string()
}

/// The four built-in provider kinds, as definitions, in a fresh vector:
/// `env`, `memory`, `dotenv` and `file` - the same four in every port.
/// `Sekreto::new` puts them in every catalog ahead of the plugins it is
/// handed.
pub fn builtins() -> Vec<Definition> {
    vec![
        providerplugin("env", |spec| {
            Ok(Rc::new(EnvProvider {
                prefix: spec.prefix.clone(),
            }) as Rc<dyn Provider>)
        }),
        providerplugin("memory", |spec| {
            Ok(Rc::new(MemoryProvider {
                values: spec.values.clone(),
                prefix: spec.prefix.clone(),
            }) as Rc<dyn Provider>)
        }),
        providerplugin("dotenv", |spec| {
            let file = if spec.file.is_empty() {
                ".env"
            } else {
                &spec.file
            };
            Ok(Rc::new(DotenvProvider::new(file, &spec.prefix)) as Rc<dyn Provider>)
        }),
        providerplugin("file", |spec| {
            Ok(Rc::new(FileProvider {
                dir: spec.dir.clone(),
                prefix: spec.prefix.clone(),
            }) as Rc<dyn Provider>)
        }),
    ]
}

/// The four kinds built into this crate.
pub const BUILTIN_KINDS: [&str; 4] = ["env", "memory", "dotenv", "file"];

/// Every kind that ships as a plugin, so that an unknown kind can be told
/// from a plugin that was not passed in.
///
/// The core names the KINDS, which are spec, and links none of the crates
/// that implement them - the list is ten strings, and a string reaches
/// nothing.
pub const PLUGIN_KINDS: [&str; 10] = [
    "hashicorp",
    "boru",
    "awssecrets",
    "awsparams",
    "gcpsecrets",
    "azuresecrets",
    "onepassword",
    "doppler",
    "infisical",
    "secretspec",
];
