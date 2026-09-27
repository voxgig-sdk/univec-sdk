// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (rust/src/providers.rs)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

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

pub trait Provider {
    fn lookup(&self, name: &str) -> Answer<Option<String>>;

    fn describe(&self) -> String;
}

/// hashicorp: log in for a token instead of being handed one.
///
/// No `Debug` derive: `secretid` and `jwt` are credentials, and
/// `tracing::error!(?spec, ...)` is the idiomatic thing to write. See the
/// hand-written impl below.
#[derive(Clone, Default)]
pub struct AuthSpec {
    pub method: String,
    pub mount: String,
    pub role: String,
    /// kubernetes: the service-account JWT itself (tests); None means the
    /// jwt file is read instead.
    pub jwt: Option<String>,
    pub jwtfile: String,
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
    pub name: String,
    pub prefix: String,
    pub file: String,
    pub values: BTreeMap<String, String>,
    pub dir: String,
    pub addr: String,
    pub token: String,
    pub mount: String,
    pub kv: u32,
    pub vaultnamespace: String,
    /// hashicorp: log in for a token instead of being handed one.
    pub auth: Option<AuthSpec>,
    pub command: String,
    pub namespace: String,
    pub home: String,
    pub profile: String,
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
    pub vault: String,
    pub tenant: String,
    pub clientid: String,
    pub clientsecret: String,
    /// azure: where to log in / where IMDS answers. gcp: where the
    /// metadata server answers. Overridable for tests and for clouds with
    /// nonstandard endpoints.
    pub loginaddr: String,
    pub imdsaddr: String,
    pub metadataaddr: String,
    pub apiversion: String,
    pub config: String,
    pub environment: String,
    pub path: String,
    pub passphrase: String,
    /// minivault: which key in the vault file to open with, defaulting to
    /// `master`. Named apart from `key` and `keyid` because those already
    /// mean a secret name and an AWS access key id.
    pub vaultkey: String,
    pub iterations: u32,
    pub create: bool,

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

fn setornot(value: &str) -> &'static str {
    if value.is_empty() {
        "[unset]"
    } else {
        "[set]"
    }
}

/// The export key under which a provider definition publishes the
/// provider it built. `Sekreto::new` reads `<ref>/provider` off the host.
pub const PROVIDER_EXPORT: &str = "provider";

pub const ERROR_CODE: &str = "sekreto_error";

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
        passphrase: gettext(options, "passphrase"),
        vaultkey: gettext(options, "vaultkey"),
        iterations: options.get("iterations").as_num().unwrap_or(0.0) as u32,
        create: matches!(options.get("create"), Value::Bool(true)),
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
    puttext(&mut out, "passphrase", &spec.passphrase);
    puttext(&mut out, "vaultkey", &spec.vaultkey);

    if 0 != spec.iterations {
        out.set("iterations", Value::Num(spec.iterations as f64));
    }

    if spec.create {
        out.set("create", Value::Bool(true));
    }

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

pub const BUILTIN_KINDS: [&str; 4] = ["env", "memory", "dotenv", "file"];

pub const PLUGIN_KINDS: [&str; 11] = [
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
    "minivault",
];
