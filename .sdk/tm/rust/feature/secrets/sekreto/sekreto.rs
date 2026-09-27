// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (rust/src/sekreto.rs)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use std::collections::BTreeMap;
use std::fmt;
use std::rc::Rc;

use super::super::plugin::catalog::{make_catalog, Catalog, Definition};
use super::super::plugin::host::Host;
use super::super::plugin::refs::{check_tag, format_ref};
use super::super::plugin::types::PluginError;
use super::super::plugin::value::Value;

use super::providers::{
    builtins, optionsof, Provider, ProviderSpec, ERROR_CODE, PLUGIN_KINDS, PROVIDER_EXPORT,
};

/// Anything sekreto refuses to do: a bad name, a missing secret, a provider
/// that could not be reached.
#[derive(Clone, Debug, PartialEq)]
pub struct SekretoError {
    pub message: String,
}

impl SekretoError {
    pub fn new(message: impl Into<String>) -> Self {
        SekretoError {
            message: message.into(),
        }
    }
}

impl fmt::Display for SekretoError {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(out, "{}", self.message)
    }
}

impl std::error::Error for SekretoError {}

impl From<String> for SekretoError {
    fn from(message: String) -> Self {
        SekretoError::new(message)
    }
}

pub type Answer<T> = Result<T, SekretoError>;

pub fn validname(name: &str) -> bool {
    if name.is_empty() {
        return false;
    }

    name.split('.').all(|part| {
        !part.is_empty()
            && part
                .chars()
                .all(|head| head.is_ascii_lowercase() || head.is_ascii_digit() || '_' == head)
    })
}

pub fn checkname(name: &str) -> Answer<()> {
    if !validname(name) {
        return Err(SekretoError::new(format!(
            "sekreto: invalid name: {}",
            name
        )));
    }
    Ok(())
}

pub fn envkey(name: &str, prefix: &str) -> Answer<String> {
    checkname(name)?;

    Ok(format!(
        "{}{}",
        prefix,
        name.split('.')
            .collect::<Vec<&str>>()
            .join("_")
            .to_uppercase()
    ))
}

#[derive(Clone, Debug, PartialEq)]
pub struct VaultRef {
    pub path: String,
    pub field: String,
}

/// Split a name into its vault path and field: `api.token` -> `api` /
/// `token`.
///
/// A single-segment name has no path of its own, so it becomes a secret of
/// that name with the conventional field `value`.
pub fn vaultref(name: &str) -> Answer<VaultRef> {
    checkname(name)?;

    let parts: Vec<&str> = name.split('.').collect();

    if 1 == parts.len() {
        return Ok(VaultRef {
            path: parts[0].to_string(),
            field: "value".to_string(),
        });
    }

    Ok(VaultRef {
        path: parts[..parts.len() - 1].join("/"),
        field: parts[parts.len() - 1].to_string(),
    })
}

pub fn flatname(name: &str, sep: &str) -> Answer<String> {
    checkname(name)?;
    let flat = name.split('.').collect::<Vec<&str>>().join(sep);
    Ok(if "-" == sep {
        flat.replace('_', "-")
    } else {
        flat
    })
}

/// The AWS SSM Parameter Store name for a name: dots become the path
/// hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
/// `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`.
pub fn awsparam(name: &str, prefix: &str) -> Answer<String> {
    checkname(name)?;

    let mut base = prefix.to_string();
    if !base.is_empty() && !base.starts_with('/') {
        base = format!("/{}", base);
    }
    if base.ends_with('/') {
        base.truncate(base.len() - 1);
    }

    Ok(format!(
        "{}/{}",
        base,
        name.split('.').collect::<Vec<&str>>().join("/")
    ))
}

pub fn parsedotenv(text: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();

    for rawline in text.split('\n') {
        let line = rawline.trim_end_matches('\r').trim();

        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let body = match line.strip_prefix("export ") {
            Some(rest) => rest.trim(),
            None => line,
        };

        let eq = match body.find('=') {
            Some(at) if 0 < at => at,
            _ => continue,
        };

        let key = body[..eq].trim().to_string();
        let mut value = body[eq + 1..].trim().to_string();

        if 2 <= value.len() && value.starts_with('"') && value.ends_with('"') {
            value = unescape(&value[1..value.len() - 1]);
        } else if 2 <= value.len() && value.starts_with('\'') && value.ends_with('\'') {
            value = value[1..value.len() - 1].to_string();
        }

        out.insert(key, value);
    }

    out
}

fn unescape(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    let mut index = 0;

    while index < chars.len() {
        if '\\' == chars[index] && index + 1 < chars.len() {
            let next = chars[index + 1];
            index += 2;
            match next {
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                '\\' => out.push('\\'),
                '"' => out.push('"'),
                _ => {
                    out.push('\\');
                    out.push(next);
                }
            }
        } else {
            out.push(chars[index]);
            index += 1;
        }
    }

    out
}

pub fn redact(text: &str, values: &[String]) -> String {
    let mut out = text.to_string();

    let mut usable: Vec<&String> = values.iter().filter(|value| 4 <= value.len()).collect();
    usable.sort_by(|left, right| right.len().cmp(&left.len()));

    for value in usable {
        out = out
            .split(value.as_str())
            .collect::<Vec<&str>>()
            .join("[redacted]");
    }

    out
}

/// The store name a provider answers to when nothing says otherwise.
///
/// `describe` opens with the provider's kind - `hashicorp:...`,
/// `dotenv:...`, plain `env` - so the kind is the natural default, and a
/// custom provider gets a sensible name without implementing anything extra.
pub fn storename(provider: &dyn Provider) -> String {
    provider
        .describe()
        .split(':')
        .next()
        .unwrap_or("")
        .to_string()
}

#[derive(Clone, Debug)]
pub enum ChainError {
    Sekreto(SekretoError),
    Plugin(PluginError),
}

impl ChainError {
    pub fn message(&self) -> String {
        match self {
            ChainError::Sekreto(err) => err.message.clone(),
            ChainError::Plugin(err) => err.message.clone(),
        }
    }
}

impl fmt::Display for ChainError {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(out, "{}", self.message())
    }
}

impl std::error::Error for ChainError {}

impl From<SekretoError> for ChainError {
    fn from(err: SekretoError) -> Self {
        ChainError::Sekreto(err)
    }
}

/// A `PluginError` back as itself when it is a `SekretoError` that crossed
/// the boundary, and as the host's report of anything else.
///
/// `providerplugin` puts the `sekreto_error` code on; this takes it off,
/// byte for byte. Nowhere else catches and rewraps.
impl From<PluginError> for ChainError {
    fn from(err: PluginError) -> Self {
        if ERROR_CODE == err.code {
            if let Some(cause) = err.details.get("cause").as_str() {
                return ChainError::Sekreto(SekretoError::new(cause));
            }
        }
        ChainError::Plugin(err)
    }
}

#[derive(Default)]
pub struct Options {
    /// The provider kinds this Sekreto may build, beyond the built-ins.
    /// A plugin naming a built-in kind replaces it.
    pub plugins: Vec<Definition>,
    pub providers: Vec<ProviderSpec>,
    pub nocache: bool,
}

struct Entry {
    store: String,
    provider: Rc<dyn Provider>,
}

pub struct Sekreto {
    /// The voxgig/plugin host every spec'd provider is an instance of, and
    /// the catalog of definitions it can build: the built-ins plus what
    /// `Options::plugins` handed in.
    host: Host,
    catalog: Catalog,

    entries: Vec<Entry>,
    docache: bool,
    // A Vec, not a map: the store a value came from stays attached, and
    // redaction order does not vary between runs.
    cache: Vec<(String, String, String)>,
    // Every value ever resolved, for redact(). Kept independently of the
    // read cache so that redaction still works when cache is off - otherwise
    // an uncached Sekreto would silently disable redact() and leak secrets
    // to logs.
    seen: Vec<String>,
}

impl Sekreto {
    pub fn new(options: Options) -> Result<Sekreto, ChainError> {
        let mut definitions = builtins();
        definitions.extend(options.plugins);
        let catalog = make_catalog(definitions)?;

        let mut sek = Sekreto {
            host: Host::with_catalog(&Value::map(), catalog.clone()),
            catalog,
            entries: Vec::new(),
            docache: !options.nocache,
            cache: Vec::new(),
            seen: Vec::new(),
        };

        for spec in &options.providers {
            // A provider already built joins the chain as it is, backed by
            // no instance: it is not a kind, so there is nothing to load.
            if let Some(provider) = &spec.provider {
                let store = if spec.name.is_empty() {
                    storename(provider.as_ref())
                } else {
                    spec.name.clone()
                };
                sek.entries.push(Entry {
                    store,
                    provider: provider.clone(),
                });
                continue;
            }

            let entry = sek.declare(spec)?;
            sek.entries.push(entry);
        }

        Ok(sek)
    }

    fn declare(&mut self, spec: &ProviderSpec) -> Result<Entry, ChainError> {
        let kind = spec.kind.as_str();

        if !self.catalog.has(kind) {
            return Err(SekretoError::new(unknownkind(kind, &self.catalog)).into());
        }

        let store = if spec.name.is_empty() {
            kind.to_string()
        } else {
            spec.name.clone()
        };

        if !check_tag(&Value::str(&store)) {
            return Err(SekretoError::new(format!("sekreto: invalid store name: {}", store)).into());
        }

        let wanted = if store == kind {
            kind.to_string()
        } else {
            format_ref(&Value::str(kind), &Value::str(&store))?
        };

        // A repeat keeps its STORE name and takes a numbered tag: `?` is
        // the host's own request for the lowest unused one.
        let mut declaration = Value::map();
        declaration.set("options", optionsof(spec));
        if self.host.instance(&Value::str(&wanted))?.is_some() {
            declaration.set("definition", Value::str(kind));
            declaration.set("tag", Value::str("?"));
        }

        // `load` runs the definition's `define`, which builds the provider
        // from the spec; `activate` takes the instance live. Nothing is
        // contacted by either: a provider opens nothing until its first
        // lookup.
        let loaded = self.host.load(&Value::str(&wanted), &declaration)?;
        let eref = loaded.borrow().eref.clone();
        self.host.activate(&Value::str(&eref))?;

        let exported = self
            .host
            .exports(&format!("{}/{}", eref, PROVIDER_EXPORT))?;

        let provider = match &exported {
            Value::Opaque(held) => held.downcast_ref::<Rc<dyn Provider>>().cloned(),
            _ => None,
        };

        match provider {
            Some(provider) => Ok(Entry { store, provider }),
            None => Err(SekretoError::new(format!(
                "sekreto: plugin {} exported no provider",
                kind
            ))
            .into()),
        }
    }

    /// The voxgig/plugin host every spec'd provider is an instance of.
    /// Read it for introspection - `list()` names each store's ref and
    /// status - and nothing on it advances the chain.
    pub fn host(&self) -> &Host {
        &self.host
    }

    pub fn catalog(&self) -> &Catalog {
        &self.catalog
    }

    /// Tear the chain down: every plugin instance is deactivated and
    /// unloaded, in reverse, releasing whatever a provider acquired at
    /// activation. Afterwards there is nothing to read from - `get` reports
    /// every secret unknown - and the cache is dropped, though `redact`
    /// still knows every value that was ever resolved.
    pub fn close(&mut self) -> Result<(), ChainError> {
        let outcome = self.host.close();

        self.entries.clear();
        self.cache.clear();

        outcome.map_err(ChainError::from)
    }

    pub fn get(&mut self, name: &str) -> Answer<String> {
        match self.trysecret(name)? {
            Some(found) => Ok(found),
            None => Err(SekretoError::new(format!(
                "sekreto: unknown secret: {}",
                name
            ))),
        }
    }

    pub fn trysecret(&mut self, name: &str) -> Answer<Option<String>> {
        self.resolve("", name, None)
    }

    pub fn getfrom(&mut self, store: &str, name: &str) -> Answer<String> {
        match self.tryfrom(store, name)? {
            Some(found) => Ok(found),
            None => Err(SekretoError::new(format!(
                "sekreto: unknown secret: {}:{}",
                store, name
            ))),
        }
    }

    pub fn tryfrom(&mut self, store: &str, name: &str) -> Answer<Option<String>> {
        if !self.entries.iter().any(|entry| entry.store == store) {
            return Err(SekretoError::new(format!(
                "sekreto: unknown store: {}",
                store
            )));
        }

        self.resolve(store, name, Some(store))
    }

    fn resolve(
        &mut self,
        cachestore: &str,
        name: &str,
        only: Option<&str>,
    ) -> Answer<Option<String>> {
        checkname(name)?;

        if self.docache {
            if let Some((_, _, found)) = self
                .cache
                .iter()
                .find(|(store, key, _)| store == cachestore && key == name)
            {
                return Ok(Some(found.clone()));
            }
        }

        for entry in &self.entries {
            if let Some(store) = only {
                if entry.store != store {
                    continue;
                }
            }

            if let Some(found) = entry.provider.lookup(name)? {
                if self.docache {
                    self.cache
                        .push((cachestore.to_string(), name.to_string(), found.clone()));
                }
                self.seen.push(found.clone());
                return Ok(Some(found));
            }
        }

        Ok(None)
    }

    pub fn has(&mut self, name: &str) -> Answer<bool> {
        Ok(self.trysecret(name)?.is_some())
    }

    pub fn hasin(&mut self, store: &str, name: &str) -> Answer<bool> {
        Ok(self.tryfrom(store, name)?.is_some())
    }

    pub fn all(&mut self, names: &[String]) -> Answer<BTreeMap<String, String>> {
        let mut out = BTreeMap::new();

        for name in names {
            out.insert(name.clone(), self.get(name)?);
        }

        Ok(out)
    }

    pub fn sources(&self) -> Vec<String> {
        self.entries
            .iter()
            .map(|entry| entry.provider.describe())
            .collect()
    }

    pub fn stores(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();

        for entry in &self.entries {
            if !out.contains(&entry.store) {
                out.push(entry.store.clone());
            }
        }

        out
    }

    /// Replace every value this Sekreto has resolved with `[redacted]`.
    ///
    /// Works whether or not caching is enabled: the redaction list is kept
    /// independently of the read cache.
    pub fn redact(&self, text: &str) -> String {
        redact(text, &self.seen)
    }

    pub fn refresh(&mut self) {
        self.cache.clear();
    }
}

fn unknownkind(kind: &str, catalog: &Catalog) -> String {
    let message = format!(
        "sekreto: unknown provider kind: {} (available: {})",
        kind,
        catalog.names().join(", ")
    );

    if PLUGIN_KINDS.contains(&kind) {
        return format!(
            "{} - {} is a sekreto plugin, not built in: pass it in the plugins option",
            message, kind
        );
    }

    message
}
