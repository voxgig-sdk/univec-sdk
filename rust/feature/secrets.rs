
pub mod plugin;
pub mod plugins;
pub mod sekreto;

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use crate::core::context::Context;
use crate::core::error::UnivecError;
use crate::core::helpers::{
    call_json, call_vfn, get_str, getp, getpath, ja, jo, json_thunk, setp, to_int, vfn,
};
use crate::core::types::{Feature, FetcherFn};
use crate::feature::support::{fopt_bool, fopt_int, fopt_list, fopt_map, fopt_str, fres_status};
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::{JsonFlags, Value};

use self::plugin::value::Value as PluginValue;
use self::sekreto::{
    envkey, specof, Answer, Options, Provider, ProviderSpec, Sekreto, SekretoError,
};

// Every refusal this feature raises carries the same error code, so a
// caller can tell a secrets failure from a transport failure.
const ERRCODE: &str = "secrets";

fn fail(msg: &str) -> UnivecError {
    UnivecError::new(ERRCODE, msg)
}

// The failure shape the Value seams already speak (system.fetch signals a
// transport failure the same way), so a provider written as a plain
// callable can report an ERROR rather than only a miss.
fn errval(msg: &str) -> Value {
    jo(vec![("__err__", Value::str(msg))])
}

/// The access-token exchange, normalised once at init. None when off, so
/// every later decision is an Option check.
#[derive(Clone)]
struct SecretsExchange {
    path: String,
    method: String,
    request: String,
    response: String,
    statuses: Vec<i64>,
    retries: i64,
}

/// Everything the transport closure needs, behind one RefCell.
///
/// Held as `Rc<RefCell<SecretsState>>` rather than as the feature's own
/// `Rc<RefCell<dyn Feature>>`: the latter is a cycle, and it is already
/// mutably borrowed while `init` runs.
pub struct SecretsState {
    sek: Option<Sekreto>,

    secretname: String,
    cache: bool,
    exchange: Option<SecretsExchange>,

    /// The client's options, READ-ONLY. This feature never writes them -
    /// see the header note.
    options: Value,
    mode: String,

    cred: String,
    refresh: String,

    /// A settled SUCCESSFUL resolution. Kept only while caching is on
    /// (`cache: false` means every request asks the chain again), and
    /// never set by a FAILURE - a transient vault outage must not poison
    /// the client permanently.
    resolved: bool,

    /// A chain that could not be built. The transport gate refuses to send
    /// while this stands, which keeps a misconfigured chain fail-closed
    /// rather than silently unauthenticated.
    initerr: Option<String>,
}

impl SecretsState {
    fn empty() -> SecretsState {
        SecretsState {
            sek: None,
            secretname: "apikey".to_string(),
            cache: true,
            exchange: None,
            options: Value::Noval,
            mode: "live".to_string(),
            cred: String::new(),
            refresh: String::new(),
            resolved: false,
            initerr: None,
        }
    }
}

struct FuncProvider {
    f: Value,
}

impl Provider for FuncProvider {
    fn lookup(&self, name: &str) -> Answer<Option<String>> {
        let out = call_vfn(&self.f, &Value::str(name));
        match &out {
            Value::Str(s) => Ok(Some(s.clone())),
            Value::Map(_) => match get_str(&out, "__err__") {
                Some(msg) => Err(SekretoError::new(msg)),
                None => Ok(None),
            },
            _ => Ok(None),
        }
    }

    fn describe(&self) -> String {
        "custom".to_string()
    }
}

fn to_plugin_value(v: &Value) -> PluginValue {
    match v {
        Value::Bool(b) => PluginValue::Bool(*b),
        Value::Num(n) => PluginValue::Num(*n),
        Value::Str(s) => PluginValue::Str(s.clone()),
        Value::List(l) => PluginValue::List(l.borrow().iter().map(to_plugin_value).collect()),
        Value::Map(m) => {
            let mut out: BTreeMap<String, PluginValue> = BTreeMap::new();
            for (k, val) in m.borrow().iter() {
                out.insert(k.to_string(), to_plugin_value(val));
            }
            PluginValue::Map(out)
        }
        _ => PluginValue::Null,
    }
}

pub struct SecretsFeature {
    pub version: String,
    pub name: String,
    pub active: bool,
    pub add_opts: Option<Value>,

    /// Providers handed in as rust objects before construction - the typed
    /// half of the custom-provider seam.
    pending: Vec<(String, Rc<dyn Provider>)>,

    pub state: Rc<RefCell<SecretsState>>,
}

impl SecretsFeature {
    pub fn new() -> SecretsFeature {
        SecretsFeature {
            version: "0.1.0".to_string(),
            name: "secrets".to_string(),
            active: true,
            add_opts: None,
            pending: Vec::new(),
            state: Rc::new(RefCell::new(SecretsState::empty())),
        }
    }

    /// Add a provider written in rust, before the client is constructed.
    /// The Value seam (`providers: [<callable>]`) covers the data path;
    /// this covers the code path, where a caller already holds an object.
    pub fn add_provider(&mut self, name: &str, provider: Rc<dyn Provider>) {
        self.pending.push((name.to_string(), provider));
    }

    /// The resolved credential (empty when none) - the state the transport
    /// injects. Read here rather than from the options map, which this
    /// feature never mutates.
    pub fn credential(&self) -> String {
        self.state.borrow().cred.clone()
    }

    pub fn resolve(&self) -> Result<(), UnivecError> {
        resolve(&self.state)
    }
}

impl Default for SecretsFeature {
    fn default() -> SecretsFeature {
        SecretsFeature::new()
    }
}

impl Feature for SecretsFeature {
    fn version(&self) -> String {
        self.version.clone()
    }
    fn name(&self) -> String {
        self.name.clone()
    }
    fn active(&self) -> bool {
        self.active
    }
    fn add_options(&self) -> Option<Value> {
        self.add_opts.clone()
    }

    fn init(&mut self, ctx: &Rc<Context>, options: &Value) {
        self.active = fopt_bool(options, "active", false);

        if !self.active {
            return;
        }

        let mut state = SecretsState::empty();

        state.mode = ctx
            .client
            .borrow()
            .clone()
            .map(|c| c.mode.borrow().clone())
            .unwrap_or_else(|| "live".to_string());
        state.options = ctx.options.borrow().clone();
        state.secretname = fopt_str(options, "name", "apikey");
        state.cache = fopt_bool(options, "cache", true);

        let xopts = fopt_map(options, "exchange");
        if fopt_bool(&xopts, "active", false) {
            let mut statuses: Vec<i64> = Vec::new();
            if let Value::List(l) = fopt_list(&xopts, "statuses") {
                for v in l.borrow().iter() {
                    statuses.push(to_int(v));
                }
            }
            if statuses.is_empty() {
                statuses.push(401);
            }
            state.exchange = Some(SecretsExchange {
                path: fopt_str(&xopts, "path", "auth/token"),
                method: fopt_str(&xopts, "method", "POST"),
                request: fopt_str(&xopts, "request", "refresh_token"),
                response: fopt_str(&xopts, "response", "access_token"),
                statuses,
                retries: fopt_int(&xopts, "retries", 1),
            });
        }

        let explicit = if state.exchange.is_none() {
            match getp(&state.options, "apikey") {
                Value::Str(s) => s,
                _ => String::new(),
            }
        } else {
            fopt_str(&xopts, "refresh", "")
        };

        let mut specs: Vec<ProviderSpec> = Vec::new();

        if !explicit.is_empty() {
            register(&state.options, &explicit);
            match envkey(&state.secretname, "") {
                Ok(key) => {
                    let mut values: BTreeMap<String, String> = BTreeMap::new();
                    values.insert(key, explicit);
                    specs.push(ProviderSpec {
                        kind: "memory".to_string(),
                        name: "options".to_string(),
                        values,
                        ..Default::default()
                    });
                }
                Err(err) => state.initerr = Some(format!("{}", err)),
            }
        }

        if let Value::List(l) = fopt_list(options, "providers") {
            for p in l.borrow().iter() {
                match p {
                    Value::Func(_) => specs.push(ProviderSpec {
                        provider: Some(Rc::new(FuncProvider { f: p.clone() })),
                        ..Default::default()
                    }),
                    Value::Map(_) => specs.push(specof(&to_plugin_value(p))),
                    _ => {
                        if state.initerr.is_none() {
                            state.initerr = Some(format!(
                                "sekreto: not a provider or a provider spec: {}",
                                vs::stringify(p, None, false)
                            ));
                        }
                    }
                }
            }
        }

        for (name, provider) in self.pending.drain(..) {
            specs.push(ProviderSpec {
                name,
                provider: Some(provider),
                ..Default::default()
            });
        }

        if state.initerr.is_none() {
            // The plugin DEFINITIONS the model selected, from the
            // GENERATED module index beside this file. Upstream sekreto's
            // contract since the registry was retired: a kind not passed
            // in is unknown to this Sekreto, so the model's choice of
            // plugin groups IS the SDK's provider vocabulary.
            match Sekreto::new(Options {
                plugins: plugins::definitions(),
                providers: specs,
                nocache: !state.cache,
            }) {
                Ok(sek) => state.sek = Some(sek),
                // Init cannot fail construction the way ts's throwing init
                // does; the transport gate refuses to send instead.
                Err(err) => state.initerr = Some(format!("{}", err)),
            }
        }

        self.state = Rc::new(RefCell::new(state));

        let shared = ctx.shared.borrow().clone();
        if let Value::Map(_) = shared {
            let h = self.state.clone();
            setp(&shared, "secrets", vfn(move |arg| secrets_call(&h, arg)));
        }

        let util = ctx.util();
        let inner: FetcherFn = util.fetcher.borrow().clone();
        let state = self.state.clone();

        *util.fetcher.borrow_mut() =
            Rc::new(move |ctx2, url, fetchdef| transport(&state, ctx2, url, fetchdef, &inner));
    }
}


fn secrets_call(state: &Rc<RefCell<SecretsState>>, arg: &Value) -> Value {
    let args: Vec<Value> = match arg {
        Value::List(l) => l.borrow().clone(),
        other => vec![other.clone()],
    };

    let text = |v: Option<&Value>| match v {
        Some(Value::Str(s)) => s.clone(),
        _ => String::new(),
    };

    let op = text(args.first());
    let a1 = text(args.get(1));
    let a2 = text(args.get(2));

    match op.as_str() {
        "credential" => Value::str(state.borrow().cred.clone()),

        "resolve" => match resolve(state) {
            Ok(()) => Value::Null,
            Err(err) => errval(&err.msg),
        },

        "get" | "getfrom" => {
            let mut s = state.borrow_mut();
            let sek = match s.sek.as_mut() {
                Some(sek) => sek,
                None => return errval("secrets: no provider chain"),
            };
            let out = if "get" == op {
                sek.get(&a1)
            } else {
                sek.getfrom(&a1, &a2)
            };
            match out {
                Ok(found) => Value::str(found),
                Err(err) => errval(&format!("{}", err)),
            }
        }

        "redact" => {
            let s = state.borrow();
            match s.sek.as_ref() {
                Some(sek) => Value::str(sek.redact(&a1)),
                None => Value::str(a1),
            }
        }

        "sources" => {
            let s = state.borrow();
            match s.sek.as_ref() {
                Some(sek) => Value::list(sek.sources().into_iter().map(Value::str).collect()),
                None => Value::empty_list(),
            }
        }

        _ => Value::Noval,
    }
}


fn resolve(state: &Rc<RefCell<SecretsState>>) -> Result<(), UnivecError> {
    {
        let s = state.borrow();
        if let Some(msg) = &s.initerr {
            return Err(fail(msg));
        }
        if s.resolved {
            return Ok(());
        }
    }

    match resolve_once(state) {
        Ok(hit) => {
            let cache = state.borrow().cache;
            if cache && hit {
                state.borrow_mut().resolved = true;
            }
            Ok(())
        }
        Err(err) => {
            state.borrow_mut().resolved = false;
            Err(err)
        }
    }
}

// Resolve once, answering whether a credential came out of it. That bool is
// the whole of what resolve needs to tell a cacheable HIT from a miss it
// must not keep.
fn resolve_once(state: &Rc<RefCell<SecretsState>>) -> Result<bool, UnivecError> {
    let name = {
        let s = state.borrow();
        if s.sek.is_none() {
            return Ok(false);
        }
        s.secretname.clone()
    };

    // The chain lookup runs under a mutable borrow (Sekreto::trysecret
    // takes &mut self for its cache), so nothing here may re-enter the
    // feature. The borrow ends before anything else is touched.
    let found = {
        let mut s = state.borrow_mut();
        let sek = s.sek.as_mut().expect("chain checked above");
        sek.trysecret(&name)
    };

    // A provider ERROR fails the op (via the transport gate); only a MISS
    // falls through.
    let found = found.map_err(|err| fail(&format!("{}", err)))?;

    if let Some(value) = &found {
        register(&state.borrow().options, value);
    }

    {
        let mut s = state.borrow_mut();

        if s.exchange.is_none() {
            let hit = found.is_some();
            s.cred = found.unwrap_or_default();
            return Ok(hit);
        }

        // Exchanging: what the chain resolved is the REFRESH token, kept
        // for every later purchase. A miss is not fatal here - an explicit
        // `apikey` may already hold a usable access token, and the API is
        // what gets to say whether it does.
        s.refresh = found.unwrap_or_default();

        if s.cred.is_empty() {
            s.cred = match getp(&s.options, "apikey") {
                Value::Str(v) => v,
                _ => String::new(),
            };
        }

        if !s.cred.is_empty() {
            // A starting access token was supplied. Spend it: if it is
            // stale the API answers with an expiry status and the wrapper
            // buys another, which is the same path expiry takes anyway.
            return Ok(true);
        }

        if !authactive(&s.options) {
            return Ok(false);
        }
    }

    buy(state).map(|_| true)
}


fn transport(
    state: &Rc<RefCell<SecretsState>>,
    ctx: &Rc<Context>,
    url: &str,
    fetchdef: &Value,
    inner: &FetcherFn,
) -> Result<Value, UnivecError> {
    resolve(state)?;

    let (token, exchanging) = {
        let s = state.borrow();
        (s.cred.clone(), s.exchange.is_some())
    };

    if !token.is_empty() {
        reauth(state, fetchdef, &token);
    }

    if !exchanging {
        return inner(ctx, url, fetchdef);
    }

    with_refresh(state, ctx, url, fetchdef, inner)
}

fn with_refresh(
    state: &Rc<RefCell<SecretsState>>,
    ctx: &Rc<Context>,
    url: &str,
    fetchdef: &Value,
    inner: &FetcherFn,
) -> Result<Value, UnivecError> {
    let (suppressed, max) = {
        let s = state.borrow();
        (
            !authactive(&s.options),
            s.exchange.as_ref().map(|x| x.retries).unwrap_or(0),
        )
    };

    if suppressed {
        return inner(ctx, url, fetchdef);
    }

    let mut attempt: i64 = 0;

    loop {
        // The credential THIS attempt goes out with, captured before it
        // leaves: it is what tells a stale refusal apart from a fresh one.
        let used = state.borrow().cred.clone();

        let out = inner(ctx, url, fetchdef);

        let res = match &out {
            Ok(res) => res.clone(),
            Err(_) => return out,
        };

        if attempt >= max || !spent(state, &res) {
            return out;
        }

        // Another request may have bought a token while this one was in
        // flight. Spend what is current before buying: a second exchange
        // for a token that is already fresh is wasted, and on a provider
        // that invalidates the previous credential on issuance it breaks
        // the first request's own retry.
        let current = state.borrow().cred.clone();

        let token = if !current.is_empty() && current != used {
            current
        } else {
            match buy(state) {
                Ok(token) => token,
                // The purchase failed: answer with the API's own refusal
                // rather than this one. The caller asked for data, and the
                // refusal is the more useful of the two - the exchange
                // error is a symptom.
                Err(_) => return out,
            }
        };

        reauth(state, fetchdef, &token);

        attempt += 1;
    }
}

fn spent(state: &Rc<RefCell<SecretsState>>, res: &Value) -> bool {
    let status = match fres_status(res) {
        Some(status) => status,
        None => return false,
    };

    let s = state.borrow();
    s.exchange
        .as_ref()
        .map(|x| x.statuses.contains(&status))
        .unwrap_or(false)
}

// Is auth ACTIVE? Read the map directly rather than through get_prop,
// which applies the Group A rule and returns the alt for a stored null -
// so it cannot tell an absent auth from a suppressed one, and only the
// latter is a suppression. Same reading make_options uses.
fn authactive(options: &Value) -> bool {
    match options {
        Value::Map(m) => matches!(m.borrow().get("auth"), Some(Value::Map(_))),
        _ => false,
    }
}

fn reauth(state: &Rc<RefCell<SecretsState>>, fetchdef: &Value, token: &str) {
    let headers = getp(fetchdef, "headers");
    if !matches!(headers, Value::Map(_)) {
        return;
    }

    let options = state.borrow().options.clone();

    // Suppressed auth means NO header, the same answer prepare_auth gives.
    // Reached defensively - with_refresh does not retry at all when auth
    // is suppressed - but this is the function that writes the credential,
    // so it is where the rule has to hold.
    if !authactive(&options) {
        vs::del_prop(headers, &Value::str("authorization"));
        return;
    }

    let prefix = match getpath(&["auth", "prefix"], &options) {
        Value::Str(s) => s,
        _ => String::new(),
    };

    // Empty prefix (a raw apiKey credential) must not add a leading space.
    if prefix.is_empty() {
        setp(&headers, "authorization", Value::str(token));
    } else {
        setp(
            &headers,
            "authorization",
            Value::str(format!("{} {}", prefix, token)),
        );
    }
}


fn buy(state: &Rc<RefCell<SecretsState>>) -> Result<String, UnivecError> {
    let (testmode, response) = {
        let s = state.borrow();
        (
            "live" != s.mode,
            s.exchange
                .as_ref()
                .map(|x| x.response.clone())
                .unwrap_or_default(),
        )
    };

    if testmode {
        let token = format!("test-{}", response);
        state.borrow_mut().cred = token.clone();
        return Ok(token);
    }

    let token = buy_once(state)?;
    state.borrow_mut().cred = token.clone();
    register(&state.borrow().options, &token);

    Ok(token)
}

// A resolved or bought value arrives under no option key the intake
// registration saw; the options map is the client's own, Rc-shared.
fn register(options: &Value, value: &str) {
    crate::utility::clean::clean_add_opts(options, value);
}

fn buy_once(state: &Rc<RefCell<SecretsState>>) -> Result<String, UnivecError> {
    let (refresh, exchange, options, secretname) = {
        let s = state.borrow();
        (
            s.refresh.clone(),
            s.exchange.clone(),
            s.options.clone(),
            s.secretname.clone(),
        )
    };

    let x = match exchange {
        Some(x) => x,
        None => return Err(fail("secrets: no exchange configured")),
    };

    if refresh.is_empty() {
        return Err(fail(&format!(
            "secrets: no refresh token: the provider chain has no '{}', \
             and feature.secrets.exchange.refresh is unset",
            secretname
        )));
    }

    let base = match getp(&options, "base") {
        Value::Str(s) => s,
        _ => String::new(),
    };
    let url = format!(
        "{}/{}",
        base.trim_end_matches('/'),
        x.path.trim_start_matches('/')
    );

    let body = vs::jsonify(
        &jo(vec![(x.request.as_str(), Value::str(refresh))]),
        Some(&JsonFlags {
            indent: 0,
            offset: 0,
        }),
    );

    let fetchdef = jo(vec![
        ("method", Value::str(x.method.clone())),
        (
            "headers",
            jo(vec![("content-type", Value::str("application/json"))]),
        ),
        ("body", Value::str(body)),
    ]);

    let sys_fetch = getpath(&["system", "fetch"], &options);

    let res = if let Value::Func(_) = sys_fetch {
        let out = call_vfn(
            &sys_fetch,
            &ja(vec![Value::str(url.clone()), fetchdef.clone()]),
        );
        if let Some(msg) = get_str(&out, "__err__") {
            return Err(fail(&msg));
        }
        out
    } else {
        raw_exchange_fetch(&url, &fetchdef)?
    };

    let status = to_int(&getp(&res, "status"));
    if !(200..300).contains(&status) {
        return Err(fail(&format!(
            "secrets: token exchange failed: {} from {}",
            status, url
        )));
    }

    let jsonfn = getp(&res, "json");
    let body = if let Value::Func(_) = jsonfn {
        call_json(&jsonfn)
    } else {
        getp(&res, "body")
    };

    let token = match getp(&body, &x.response) {
        Value::Str(s) => s,
        _ => String::new(),
    };

    if token.is_empty() {
        return Err(fail(&format!(
            "secrets: token exchange returned no '{}' field from {}",
            x.response, url
        )));
    }

    Ok(token)
}

fn raw_exchange_fetch(fullurl: &str, fetchdef: &Value) -> Result<Value, UnivecError> {
    let method = get_str(fetchdef, "method")
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| "POST".to_string());

    let agent = crate::utility::fetcher::default_agent();
    let mut req = agent.request(&method, fullurl);

    if let Value::Map(m) = getp(fetchdef, "headers") {
        for (k, v) in m.borrow().iter() {
            if let Value::Str(sv) = v {
                req = req.set(k, sv);
            }
        }
    }

    let body = get_str(fetchdef, "body").unwrap_or_default();

    let sent = if body.is_empty() {
        req.call()
    } else {
        req.send_string(&body)
    };

    let resp = match sent {
        Ok(resp) => resp,
        Err(ureq::Error::Status(_code, resp)) => resp,
        Err(err) => return Err(fail(&format!("secrets: token exchange: {}", err))),
    };

    let status = resp.status() as i64;

    let text = resp
        .into_string()
        .map_err(|err| fail(&format!("secrets: token exchange body: {}", err)))?;

    let parsed = if text.is_empty() {
        Value::Noval
    } else {
        crate::utility::jsonparse::json_parse(&text).unwrap_or(Value::Noval)
    };

    Ok(jo(vec![
        ("status", Value::Num(status as f64)),
        ("json", json_thunk(parsed)),
    ]))
}
