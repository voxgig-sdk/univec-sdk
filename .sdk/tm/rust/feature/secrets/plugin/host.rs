// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (rust/src/host.rs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The host: the lifecycle state machine (§5), extension points (§6), and
//! resource capture (§8).
//!
//! TWO RULES SHAPE EVERY METHOD BELOW.
//!
//! Transitions are SEQUENTIAL (§5.2). One at a time, in call order, never
//! interleaved; a transition triggered from inside a lifecycle callback is
//! `plugin_reentrant`. A hard rule, because it is the only way the
//! semantics can be identical in Go, in Rust and in single-threaded
//! JavaScript.
//!
//! Reconciliation is EAGER (§18's portability budget). A transition
//! settles by running the state machine to a fixed point, not by
//! suspending on a promise.
//!
//! AND ONE RULE IS RUST'S OWN: NEVER HOLD A BORROW ACROSS A CALLBACK. A
//! definition's `define` calls back into the host - `bind`, `export`,
//! `acquire`, even `nest` - so every method here reads what it needs out
//! of a `RefCell`, DROPS the borrow, and only then runs anything a plugin
//! wrote. A held borrow does not produce a wrong answer, it panics, which
//! is the one failure mode a conformance suite cannot report as a
//! divergence.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use super::capability::resolve_capability;
use super::catalog::{Catalog, Definition};
use super::config::{normalize_config, resolve_options};
use super::depend::{checkcycle, gatesactivation, requirements, restartsonloss, Node};
use super::export::{resolve_export, Exported};
use super::order::{resolve_order, Binding};
use super::point::{compose, point_emit, point_provider, Bound, NextFn};
use super::refs::{canon, canon_ref, format_ref, parse_ref, refname};
use super::types::{details, fail, PluginError};
use super::value::Value;

/// A registered teardown. §8.3's scope: every entry runs, in reverse, and
/// a failing one does not stop the rest.
pub type ScopeFn = Rc<dyn Fn() -> Result<(), PluginError>>;

/// One instance's record.
pub struct Entry {
    pub eref: String,
    pub def: Rc<Definition>,
    pub status: String,
    pub pos: f64,
    pub seq: f64,
    pub options: Value,
    pub state: Value,
    pub order: Value,
    pub unmet: Vec<String>,
    pub scope: Vec<ScopeFn>,
    /// §11.4's ALWAYS-RELUCTANT rebinding made concrete: the provider ref
    /// this instance's activation actually chose, per requirement name.
    /// Re-ranking on every question silently re-points a live consumer at
    /// any better newcomer, and then losing the provider it was really
    /// using does not restart it.
    pub selected: BTreeMap<String, String>,
    pub bindings: Vec<Bound>,
    pub exports: BTreeMap<String, Value>,
    pub provides: Vec<Value>,
    pub inner: Option<Host>,
    pub barred: bool,
}

pub struct HostInner {
    opts: Value,
    dependency: String,
    reserved: Value,
    points: Value,
    catalog: RefCell<Catalog>,
    inst: RefCell<BTreeMap<String, Rc<RefCell<Entry>>>>,
    log: RefCell<Vec<String>>,
    /// §14: the lifecycle event record. `seq` distinguishes ONE
    /// INCARNATION of stripe$test from the next, which is the whole reason
    /// it is not `pos` (§4 rule 4).
    events: RefCell<Vec<Value>>,
    seqn: Cell<f64>,
    open: Cell<i64>,
    transition: Cell<bool>,
    /// WHICH callback is running, not merely that one is. §8.1 puts
    /// resource capture in `activate` and 8.3 says `release` outside
    /// `activate` is `plugin_release_scope` - and a bare flag cannot tell
    /// `activate` from `define`, so it admitted an acquire in `define`
    /// whose scope `unload` would never unwind.
    phase: RefCell<String>,
    /// Set for the duration of a bulk teardown, so `held` knows this is a
    /// coordinated operation rather than an ad-hoc deactivation.
    coordinated: Cell<bool>,
}

#[derive(Clone)]
pub struct Host(pub Rc<HostInner>);

pub fn make_host(options: &Value) -> Host {
    Host::new(options)
}

impl Host {
    pub fn new(options: &Value) -> Host {
        let opts = options.clone();
        let dependency = opts
            .get("dependency")
            .as_str()
            .unwrap_or("restart")
            .to_string();
        Host(Rc::new(HostInner {
            reserved: opts.get("reserved"),
            points: opts.get("points"),
            catalog: RefCell::new(Catalog::new()),
            inst: RefCell::new(BTreeMap::new()),
            log: RefCell::new(Vec::new()),
            events: RefCell::new(Vec::new()),
            seqn: Cell::new(0.0),
            open: Cell::new(0),
            transition: Cell::new(false),
            phase: RefCell::new(String::new()),
            coordinated: Cell::new(false),
            dependency,
            opts,
        }))
    }

    pub fn with_catalog(options: &Value, catalog: Catalog) -> Host {
        let host = Host::new(options);
        *host.0.catalog.borrow_mut() = catalog;
        host
    }

    pub fn define(&self, definition: Definition) -> Result<(), PluginError> {
        self.0.catalog.borrow_mut().add(definition)
    }

    pub fn intransition(&self) -> bool {
        self.0.transition.get()
    }

    pub fn phase(&self) -> String {
        self.0.phase.borrow().clone()
    }

    pub fn haspoint(&self, name: &str) -> bool {
        self.0.points.has(name)
    }

    pub fn open_inc(&self) {
        self.0.open.set(self.0.open.get() + 1);
    }

    pub fn open_dec(&self) {
        self.0.open.set(self.0.open.get() - 1);
    }

    // --- observation ------------------------------------------------

    /// Introspection NEVER advances the state (§5.2). A status page must
    /// not be a way to accidentally import twenty packages.
    pub fn list(&self) -> Value {
        let mut out = Value::map();
        for (eref, entry) in self.0.inst.borrow().iter() {
            out.set(eref, Value::str(&entry.borrow().status));
        }
        out
    }

    /// The instance record, or `None` when nothing is registered under
    /// that ref. THE REF IS VALIDATED, not merely canonicalized: looking
    /// an instance up by `"bad name"` is `plugin_bad_name`, not a quiet
    /// miss, and `declare/lookup#malformed` is the entry that says so.
    pub fn instance(&self, eref: &Value) -> Result<Option<Rc<RefCell<Entry>>>, PluginError> {
        let r = canon_ref(eref)?;
        Ok(self.0.inst.borrow().get(&r).cloned())
    }

    pub fn trace(&self) -> Value {
        Value::List(self.0.events.borrow().clone())
    }

    pub fn observable(&self, result: Value) -> Value {
        let mut out = Value::map();
        out.set("status", self.list());
        out.set("open", Value::Num(self.0.open.get() as f64));
        out.set(
            "log",
            Value::List(self.0.log.borrow().iter().map(|l| Value::str(l)).collect()),
        );
        out.set("result", result);
        out
    }

    // --- the state machine ------------------------------------------

    fn guard(&self) -> Result<(), PluginError> {
        if !self.0.transition.get() {
            return Ok(());
        }
        fail(
            "plugin_reentrant",
            "transition attempted from inside a lifecycle callback",
            Value::Null,
        )
    }

    fn need(&self, eref: &Value) -> Result<Rc<RefCell<Entry>>, PluginError> {
        let r = canon_ref(eref)?;
        match self.0.inst.borrow().get(&r) {
            Some(e) => Ok(e.clone()),
            None => fail(
                "plugin_not_loaded",
                &format!("no such instance: {}", r),
                details(&[("ref", Value::str(&r))]),
            ),
        }
    }

    fn checkreserved(&self, eref: &str) -> Result<(), PluginError> {
        let list = match self.0.reserved.as_list() {
            Some(l) if !l.is_empty() => l.clone(),
            _ => return Ok(()),
        };
        let name = refname(eref);
        if !list.iter().any(|r| r.as_str() == Some(name.as_str())) {
            return Ok(());
        }
        fail(
            "plugin_ref_reserved",
            &format!("ref is reserved by the host: {}", eref),
            details(&[("ref", Value::str(eref))]),
        )
    }

    fn run(
        &self,
        entry: &Rc<RefCell<Entry>>,
        callback: &str,
        at: &str,
    ) -> Result<(), PluginError> {
        // Read everything the log and the event record need, then DROP the
        // borrow: the callback below reaches back into this entry.
        let (eref, seq, status, def) = {
            let e = entry.borrow();
            (e.eref.clone(), e.seq, e.status.clone(), e.def.clone())
        };

        self.0.log.borrow_mut().push(format!("{}:{}", eref, at));
        let mut event = Value::map();
        event.set("ref", Value::str(&eref));
        event.set("event", Value::str(at));
        event.set("seq", Value::Num(seq));
        event.set("status", Value::str(&status));
        self.0.events.borrow_mut().push(event);

        let func = match def.callback(callback) {
            Some(f) => f,
            None => return Ok(()),
        };

        self.0.transition.set(true);
        *self.0.phase.borrow_mut() = at.to_string();
        let inst = Inst::new(self.clone(), entry.clone())?;
        let outcome = func(&inst);
        self.0.transition.set(false);
        self.0.phase.borrow_mut().clear();

        match outcome {
            Ok(()) => Ok(()),
            // §12: `plugin_define_failed` and its three siblings are "a
            // callback raised; wraps the cause". AN ERROR THAT ALREADY
            // CARRIES A CODE KEEPS IT - the code is the error's identity,
            // and a plugin raising `store_unreachable` must not have it
            // rewritten. Only a code-less error is wrapped.
            Err(e) if !e.code.is_empty() => Err(e),
            Err(e) => fail(
                &format!("plugin_{}_failed", at),
                &format!("{} raised in {}: {}", eref, at, e.message),
                details(&[
                    ("ref", Value::str(&eref)),
                    ("cause", Value::str(&e.message)),
                ]),
            ),
        }
    }

    /// AUTO-TAGGING IS EXPLICIT (§4 rule 3). `declare('stripe', tag: '?')`
    /// assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns the
    /// assigned pair. Without `'?'`, a collision is an error.
    fn autotag(&self, name: &str) -> Result<String, PluginError> {
        let mut n = 1;
        loop {
            let cand = format_ref(&Value::str(name), &Value::str(&n.to_string()))?;
            if !self.0.inst.borrow().contains_key(&cand) {
                return Ok(cand);
            }
            n += 1;
        }
    }

    pub fn declare(&self, eref: &Value, spec: &Value) -> Result<Rc<RefCell<Entry>>, PluginError> {
        let eref = if spec.get("tag").as_str() == Some("?") {
            Value::str(&self.autotag(&refname(&canon_ref(eref)?))?)
        } else {
            eref.clone()
        };
        let r = canon_ref(&eref)?;
        if !spec.get("hostowned").truthy() {
            self.checkreserved(&r)?;
        }
        let defname = spec
            .get("definition")
            .as_str()
            .map(|s| s.to_string())
            .unwrap_or_else(|| refname(&r));
        let definition = match self.0.catalog.borrow().get(&defname) {
            Some(d) => d,
            None => {
                return fail(
                    "plugin_unknown_definition",
                    &format!("not in catalog: {}", defname),
                    details(&[("name", Value::str(&defname))]),
                )
            }
        };

        let existing = self.0.inst.borrow().get(&r).cloned();
        if let Some(existing) = existing {
            // §4 rule 1: a pair addresses at most one instance.
            // Re-declaring the SAME definition is the idempotent case; a
            // different one is a duplicate, not a silent overwrite
            // (seneca) and not an impossibility (sdkgen).
            if existing.borrow().def.name != definition.name {
                return fail(
                    "plugin_ref_duplicate",
                    &format!("instance already declared: {}", r),
                    details(&[("ref", Value::str(&r))]),
                );
            }
            return Ok(existing);
        }

        let pos = match spec.get("pos").as_num() {
            Some(p) => p,
            None => self.0.inst.borrow().len() as f64,
        };
        let entry = Rc::new(RefCell::new(Entry {
            eref: r.clone(),
            def: definition,
            status: "declared".to_string(),
            pos,
            seq: self.0.seqn.get(),
            options: if spec.get("options").is_null() {
                Value::map()
            } else {
                spec.get("options")
            },
            state: Value::map(),
            order: spec.get("order"),
            unmet: Vec::new(),
            scope: Vec::new(),
            selected: BTreeMap::new(),
            bindings: Vec::new(),
            exports: BTreeMap::new(),
            provides: Vec::new(),
            inner: None,
            barred: false,
        }));
        self.0.seqn.set(self.0.seqn.get() + 1.0);
        self.0.inst.borrow_mut().insert(r, entry.clone());
        Ok(entry)
    }

    /// §9.1: a host that reserves a name MUST still be able to declare the
    /// instance it reserved - "The host declares those instances itself,
    /// after the user merge, and always wins."
    ///
    /// THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit:
    /// no language here can tell the embedding host from a plugin holding
    /// the same host object. What reservation protects is CONFIGURATION -
    /// documents, overlays, `VOXGIG_PLUGIN_*`, construction options and
    /// ordinary declare/load/options - and all of that still checks.
    pub fn hostdeclare(
        &self,
        eref: &Value,
        spec: &Value,
    ) -> Result<Rc<RefCell<Entry>>, PluginError> {
        self.guard()?;
        let mut spec = spec.clone();
        if spec.as_map().is_none() {
            spec = Value::map();
        }
        spec.set("hostowned", Value::Bool(true));
        self.declare(eref, &spec)
    }

    pub fn load(&self, eref: &Value, spec: &Value) -> Result<Rc<RefCell<Entry>>, PluginError> {
        self.guard()?;
        let entry = self.declare(eref, spec)?;
        if "declared" != entry.borrow().status {
            return Ok(entry); // idempotent trivially
        }

        // PRESENCE, NOT TRUTH: an empty options map must CLEAR what the
        // instance was declared with.
        if spec.has("options") && !spec.get("options").is_null() {
            entry.borrow_mut().options = spec.get("options");
        }
        if let Err(e) = self.run(&entry, "define", "define") {
            entry.borrow_mut().status = "failed".to_string();
            return Err(e);
        }
        entry.borrow_mut().status = "loaded".to_string();

        // AT LOAD, and before anything runs: a cycle through
        // restart-causing requirements does not settle, and the only safe
        // time to report a non-terminating reconcile is before it starts
        // (§11.3). `provides` is populated by `define`, which has just
        // run, so this is the first moment the graph is complete.
        if let Err(e) = checkcycle(&self.graphnodes()) {
            entry.borrow_mut().status = "failed".to_string();
            return Err(e);
        }
        Ok(entry)
    }

    /// The requirement graph as plain data, for the pure detector.
    fn graphnodes(&self) -> Vec<Node> {
        let mut out = Vec::new();
        for (eref, entry) in self.0.inst.borrow().iter() {
            let e = entry.borrow();
            out.push(Node {
                eref: eref.clone(),
                provides: e
                    .provides
                    .iter()
                    .map(|p| p.get("name").as_str().unwrap_or("").to_string())
                    .collect(),
                requires: requirements(&e.options),
            });
        }
        out
    }

    pub fn activate(&self, eref: &Value) -> Result<Rc<RefCell<Entry>>, PluginError> {
        self.guard()?;
        let entry = self.need(eref)?;
        let (status, barred, myref) = {
            let e = entry.borrow();
            (e.status.clone(), e.barred, e.eref.clone())
        };
        if "live" == status {
            return Ok(entry); // no-op returning success
        }
        if "failed" == status {
            return fail(
                "plugin_bad_state",
                &format!("instance has failed: {}", myref),
                details(&[("ref", Value::str(&myref))]),
            );
        }
        // §9.6: `active: false` bars the instance from running, and the
        // bar is on the INSTANCE rather than on the apply that set it.
        // `ready` reaches this through `activate`, so one guard covers
        // both verbs the design names.
        if barred {
            return fail(
                "plugin_inactive",
                &format!("instance is barred by active: false: {}", myref),
                details(&[("ref", Value::str(&myref))]),
            );
        }
        if "declared" == status {
            self.load(&Value::str(&myref), &Value::map())?;
        }

        // A declared requirement that is not live means `pending`:
        // activation is a STANDING REQUEST, not a one-shot event.
        let unmet = self.unmetof(&entry);
        if !unmet.is_empty() {
            let mut e = entry.borrow_mut();
            e.unmet = unmet;
            e.status = "pending".to_string();
            return Ok(entry.clone());
        }

        if let Err(err) = self.run(&entry, "activate", "activate") {
            // Unwind whatever the partial activation captured, in reverse.
            self.unwind(&entry);
            entry.borrow_mut().status = "failed".to_string();
            return Err(err);
        }
        // §11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
        // later question - the cascade, `hold`, `unmet` - reads it back
        // rather than re-ranking, which is what "always-reluctant" means.
        let reqs = requirements(&entry.borrow().options);
        for req in reqs.iter() {
            self.chosen(&entry, req, true);
        }
        entry.borrow_mut().status = "live".to_string();
        self.reconcile();
        Ok(entry)
    }

    pub fn deactivate(&self, eref: &Value) -> Result<Rc<RefCell<Entry>>, PluginError> {
        self.guard()?;
        let entry = self.need(eref)?;
        let (status, myref) = {
            let e = entry.borrow();
            (e.status.clone(), e.eref.clone())
        };
        if "loaded" == status || "declared" == status {
            return Ok(entry);
        }

        // §5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
        if "failed" == status {
            return fail(
                "plugin_bad_state",
                &format!("instance has failed: {}", myref),
                details(&[("ref", Value::str(&myref))]),
            );
        }

        if "pending" == status {
            // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It
            // never reached activate, so it holds no scope and no live
            // bindings; running the definition's deactivate there would be
            // teardown without matching setup, which plugins are not
            // written to survive and which could fail an instance that had
            // done nothing wrong. It cannot fail.
            let mut e = entry.borrow_mut();
            e.status = "loaded".to_string();
            e.unmet = Vec::new();
            return Ok(entry.clone());
        }

        self.held(&myref)?;
        self.cascade(&myref, &mut BTreeSet::new());

        if let Err(err) = self.run(&entry, "deactivate", "deactivate") {
            self.unwind(&entry);
            entry.borrow_mut().status = "failed".to_string();
            return Err(err);
        }
        let errors = self.unwind(&entry);
        self.releasecheck(&entry, errors)?;
        entry.borrow_mut().status = "loaded".to_string();
        self.reconcile();
        Ok(entry)
    }

    pub fn unload(&self, eref: &Value) -> Result<(), PluginError> {
        self.guard()?;
        let entry = self.need(eref)?;
        let (mut status, myref) = {
            let e = entry.borrow();
            (e.status.clone(), e.eref.clone())
        };

        if "live" == status || "pending" == status {
            if "live" == status {
                self.held(&myref)?;
                self.cascade(&myref, &mut BTreeSet::new());
                if let Err(err) = self.run(&entry, "deactivate", "deactivate") {
                    // §5.2: ANY failure during a transition lands the
                    // instance in `failed`, with the scope STILL FULLY
                    // UNWOUND - and the instance STAYS REGISTERED, because
                    // `failed` is a state an operator has to be able to
                    // see.
                    self.unwind(&entry);
                    entry.borrow_mut().status = "failed".to_string();
                    return Err(err);
                }
                let errors = self.unwind(&entry);
                self.releasecheck(&entry, errors)?;
            }
            entry.borrow_mut().status = "loaded".to_string();
            status = "loaded".to_string();
        }

        if "loaded" == status || "failed" == status {
            let outcome = self.run(&entry, "close", "close");
            self.0.inst.borrow_mut().remove(&myref);
            return outcome;
        }
        self.0.inst.borrow_mut().remove(&myref);
        Ok(())
    }

    /// Runs the whole forward path in one call (§5.1).
    pub fn ready(&self, eref: &Value) -> Result<Rc<RefCell<Entry>>, PluginError> {
        self.guard()?;
        let r = canon_ref(eref)?;
        let known = self.0.inst.borrow().contains_key(&r);
        if !known {
            self.declare(&Value::str(&r), &Value::map())?;
        }
        let declared = "declared" == self.0.inst.borrow()[&r].borrow().status;
        if declared {
            self.load(&Value::str(&r), &Value::map())?;
        }
        self.activate(&Value::str(&r))
    }

    /// Bindings go live only when activation succeeds (§8.1), so the
    /// teardown is the exact inverse: reverse order, always. Returns the
    /// errors the scope raised. §8.3: "A failing release does not stop the
    /// rest. Every entry runs, in reverse order, whatever any of them
    /// does; the errors are collected and raised as one
    /// `plugin_release_failed`."
    ///
    /// A selection belongs to ONE activation (§11.4). Leaving `live` by
    /// any door drops it, so the next activation ranks afresh - keeping it
    /// would make a consumer prefer a provider it never actually ran
    /// against.
    fn unwind(&self, entry: &Rc<RefCell<Entry>>) -> Vec<PluginError> {
        // TAKE the scope out under a short borrow: the closures below
        // reach back into this same entry (a foreign release records its
        // index in `state`), and holding the borrow would panic.
        let scope = {
            let mut e = entry.borrow_mut();
            e.selected = BTreeMap::new();
            std::mem::take(&mut e.scope)
        };
        let mut errors = Vec::new();
        for func in scope.iter().rev() {
            if let Err(e) = func() {
                errors.push(e);
            }
        }
        errors
    }

    /// §8.3: "A failed release ends the instance in `failed`, exactly as a
    /// failed callback does (5.2) - a release that raised may have leaked,
    /// and an instance that may be holding resources it cannot account for
    /// must not be reactivated."
    fn releasecheck(
        &self,
        entry: &Rc<RefCell<Entry>>,
        errors: Vec<PluginError>,
    ) -> Result<(), PluginError> {
        if errors.is_empty() {
            return Ok(());
        }
        let myref = entry.borrow().eref.clone();
        entry.borrow_mut().status = "failed".to_string();
        let causes: Vec<String> = errors.iter().map(|e| e.message.clone()).collect();
        fail(
            "plugin_release_failed",
            &format!("release failed for {}: {}", myref, causes.join("; ")),
            details(&[
                ("ref", Value::str(&myref)),
                (
                    "cause",
                    Value::List(causes.iter().map(|c| Value::str(c)).collect()),
                ),
            ]),
        )
    }

    /// A REQUIREMENT IS ON A CAPABILITY, not on a ref (§11.1). A bare
    /// string is shorthand for `{name}`. A ref satisfies too, because a
    /// host that genuinely needs a specific instance should not have to
    /// invent a capability for it.
    fn unmetof(&self, entry: &Rc<RefCell<Entry>>) -> Vec<String> {
        let reqs = requirements(&entry.borrow().options);
        reqs.iter()
            .filter(|r| gatesactivation(r))
            .filter(|r| self.providersof(r).is_empty())
            .map(|r| r.get("name").as_str().unwrap_or("").to_string())
            .collect()
    }

    /// §11.4's always-reluctant selection, and the ONE place a provider is
    /// picked for a live instance. If this instance already selected a
    /// provider for `req` and that provider is STILL a candidate, it keeps
    /// it - a better-ranked newcomer does not take it.
    ///
    /// `remember` is false for the questions asked ABOUT an instance
    /// rather than BY it: introspection must not create a binding.
    fn chosen(&self, entry: &Rc<RefCell<Entry>>, req: &Value, remember: bool) -> Option<String> {
        let cands = self.providersof(req);
        if cands.is_empty() {
            return None;
        }
        let name = req.get("name").as_str().unwrap_or("").to_string();
        let held = entry.borrow().selected.get(&name).cloned();
        if let Some(held) = held {
            if cands
                .iter()
                .any(|c| c.get("ref").as_str() == Some(held.as_str()))
            {
                return Some(held);
            }
        }
        let best = cands[0].get("ref").as_str().unwrap_or("").to_string();
        if remember {
            entry.borrow_mut().selected.insert(name, best.clone());
        }
        Some(best)
    }

    fn boundproviders(&self, entry: &Rc<RefCell<Entry>>) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for req in requirements(&entry.borrow().options).iter() {
            if !restartsonloss(req) {
                continue;
            }
            if let Some(r) = self.chosen(entry, req, false) {
                if !out.contains(&r) {
                    out.push(r);
                }
            }
        }
        out
    }

    /// Live instances whose selected provider is `eref` and which would be
    /// restarted by losing it.
    fn consumersof(&self, eref: &str) -> Vec<String> {
        let all: Vec<(String, Rc<RefCell<Entry>>)> = self
            .0
            .inst
            .borrow()
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        all.iter()
            .filter(|(r, c)| r != eref && "live" == c.borrow().status)
            .filter(|(_, c)| self.boundproviders(c).iter().any(|p| p == eref))
            .map(|(r, _)| r.clone())
            .collect()
    }

    /// §11.3's `hold` asks a DIFFERENT question from the cascade, and
    /// reading it off `consumersof` answered the cascade's.
    ///
    /// The cascade wants the edges that RESTART - mandatory-static and
    /// optional-static - because a restart is what it performs. `hold`
    /// says "deactivating a REQUIRED instance is
    /// `plugin_dependency_held`", and required is cardinality:
    /// `gatesactivation`, not `restartsonloss`. The two sets differ in
    /// both directions and each difference was a real bug.
    fn holdersof(&self, eref: &str) -> Vec<String> {
        let all: Vec<(String, Rc<RefCell<Entry>>)> = self
            .0
            .inst
            .borrow()
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let mut out = Vec::new();
        for (r, c) in all.iter() {
            if r == eref || "live" != c.borrow().status {
                continue;
            }
            for req in requirements(&c.borrow().options).iter() {
                if !gatesactivation(req) {
                    continue;
                }
                if self.chosen(c, req, false).as_deref() == Some(eref) {
                    out.push(r.clone());
                    break;
                }
            }
        }
        out
    }

    fn providersof(&self, req: &Value) -> Vec<Value> {
        let want = canon(req.get("name").as_str().unwrap_or(""));
        let name = req.get("name");
        let mut cands: Vec<Value> = Vec::new();
        let all: Vec<(String, Rc<RefCell<Entry>>)> = self
            .0
            .inst
            .borrow()
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        for (eref, target) in all.iter() {
            let t = target.borrow();
            if "live" != t.status {
                continue;
            }
            // A ref satisfies directly.
            if *eref == want {
                let mut cand = Value::map();
                cand.set("ref", Value::str(eref));
                cand.set("pos", Value::Num(t.pos));
                let mut prov = Value::map();
                prov.set("name", name.clone());
                cand.set("provides", prov);
                cands.push(cand);
                continue;
            }
            for prov in t.provides.iter() {
                if !prov.get("name").same(&name) {
                    continue;
                }
                let mut cand = Value::map();
                cand.set("ref", Value::str(eref));
                cand.set("pos", Value::Num(t.pos));
                cand.set("provides", prov.clone());
                cands.push(cand);
            }
        }
        resolve_capability(req, &cands)
    }

    /// CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).
    ///
    /// The cascade is part of the provider's own deactivation and runs
    /// BEFORE the provider's `deactivate` callback and scope unwind, so a
    /// consumer's teardown can still call the thing it depends on -
    /// flushing a buffer to the store it is about to lose is exactly what
    /// a `deactivate` callback is for, and a cascade that fired after the
    /// provider was already gone would make that impossible.
    fn cascade(&self, provider: &str, seen: &mut BTreeSet<String>) {
        if seen.contains(provider) {
            return;
        }
        seen.insert(provider.to_string());

        for r in self.consumersof(provider) {
            let consumer = match self.0.inst.borrow().get(&r) {
                Some(c) => c.clone(),
                None => continue,
            };
            if "live" != consumer.borrow().status {
                continue;
            }

            self.cascade(&r, seen); // deepest-first
            let bad = self.run(&consumer, "deactivate", "deactivate").is_err();
            let errors = self.unwind(&consumer);
            if bad || !errors.is_empty() {
                // §5.2: ANY failure during a transition lands the instance
                // in `failed`. Marking it `pending` handed it straight
                // back to `reconcile`, which would activate it again the
                // moment the provider returned.
                consumer.borrow_mut().status = "failed".to_string();
                continue;
            }
            let unmet = self.unmetof(&consumer);
            let mut c = consumer.borrow_mut();
            c.status = "pending".to_string();
            c.unmet = unmet;
        }
    }

    /// The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON
    /// COORDINATED TEARDOWN. In a bulk operation that is removing the
    /// holders too - `close`, or an `apply` plan whose own steps
    /// deactivate them - it is suspended for exactly those holders, and
    /// the teardown still runs consumers before providers.
    fn held(&self, eref: &str) -> Result<(), PluginError> {
        if "hold" != self.0.dependency {
            return Ok(());
        }
        if self.0.coordinated.get() {
            return Ok(());
        }
        let holders = self.holdersof(eref);
        if holders.is_empty() {
            return Ok(());
        }
        fail(
            "plugin_dependency_held",
            &format!("instance is required by live consumers: {}", eref),
            details(&[
                ("ref", Value::str(eref)),
                (
                    "holders",
                    Value::List(holders.iter().map(|h| Value::str(h)).collect()),
                ),
            ]),
        )
    }

    /// EAGER reconciliation: run to a fixed point rather than scheduling.
    ///
    /// Two directions, and both are the reason `pending` exists.
    /// Activation is a STANDING REQUEST, not a one-shot event.
    fn reconcile(&self) {
        let mut moved = true;
        let mut rounds = 0;
        while moved {
            moved = false;
            rounds += 1;
            if 1000 < rounds {
                break;
            }

            // Losses first, so a cascade settles in one pass rather than
            // alternating with re-activations.
            let refs: Vec<String> = self.0.inst.borrow().keys().cloned().collect();
            for r in refs.iter() {
                let entry = match self.0.inst.borrow().get(r) {
                    Some(e) => e.clone(),
                    None => continue,
                };
                if "live" != entry.borrow().status {
                    continue;
                }
                let reqs = requirements(&entry.borrow().options);
                let lost: Vec<&Value> = reqs
                    .iter()
                    .filter(|q| gatesactivation(q))
                    .filter(|q| self.providersof(q).is_empty())
                    .collect();
                if lost.is_empty() {
                    continue;
                }
                // POLICY IS PER REQUIREMENT, not per instance (§11.3). A
                // `dynamic` requirement whose provider is gone leaves the
                // consumer LIVE and notified.
                if !lost.iter().any(|q| restartsonloss(q)) {
                    continue;
                }

                let bad = self.run(&entry, "deactivate", "deactivate").is_err();
                let errors = self.unwind(&entry);
                if bad || !errors.is_empty() {
                    entry.borrow_mut().status = "failed".to_string();
                    moved = true;
                    continue;
                }
                let unmet = self.unmetof(&entry);
                let mut e = entry.borrow_mut();
                e.status = "pending".to_string();
                e.unmet = unmet;
                moved = true;
            }

            let refs: Vec<String> = self.0.inst.borrow().keys().cloned().collect();
            for r in refs.iter() {
                let entry = match self.0.inst.borrow().get(r) {
                    Some(e) => e.clone(),
                    None => continue,
                };
                if "pending" != entry.borrow().status {
                    continue;
                }
                if !self.unmetof(&entry).is_empty() {
                    continue;
                }
                match self.run(&entry, "activate", "activate") {
                    Ok(()) => {
                        let mut e = entry.borrow_mut();
                        e.status = "live".to_string();
                        e.unmet = Vec::new();
                        moved = true;
                    }
                    Err(_) => {
                        self.unwind(&entry);
                        entry.borrow_mut().status = "failed".to_string();
                        moved = true;
                    }
                }
            }
        }
    }

    // --- ordering ---------------------------------------------------

    pub fn order(&self, point: Option<&str>) -> Result<Vec<String>, PluginError> {
        // Sorted by declaration SEQUENCE, which is what makes the §7
        // sort's fall-through deterministic in a language whose maps have
        // no insertion order. §7 breaks ties by `pos`; two instances CAN
        // share one - `declare` defaults `pos` to the registry size, so an
        // unload followed by a fresh declare reuses a surviving
        // instance's - and past that this was falling through to map
        // order. `seq` is that order, made explicit.
        let mut live: Vec<Binding> = Vec::new();
        for entry in self.0.inst.borrow().values() {
            let e = entry.borrow();
            if "live" != e.status {
                continue;
            }
            live.push(Binding {
                eref: e.eref.clone(),
                pos: e.pos,
                order: e.order.clone(),
            });
        }
        let seqof: BTreeMap<String, f64> = self
            .0
            .inst
            .borrow()
            .iter()
            .map(|(k, v)| (k.clone(), v.borrow().seq))
            .collect();
        live.sort_by(|a, b| {
            seqof[&a.eref]
                .partial_cmp(&seqof[&b.eref])
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let pin = match point {
            Some(p) => self.0.points.get(p).get("pin"),
            None => Value::Null,
        };
        resolve_order(&live, &pin)
    }

    // --- points -----------------------------------------------------

    /// Live bindings on a point, in resolved order. Recomputed on any
    /// change to the live set (§7) rather than cached at startup - the bug
    /// a host discovers only when something deactivates in production.
    fn bound(&self, point: &str) -> Result<Vec<Bound>, PluginError> {
        let mut out = Vec::new();
        for eref in self.order(Some(point))? {
            let entry = match self.0.inst.borrow().get(&eref) {
                Some(e) => e.clone(),
                None => continue,
            };
            let e = entry.borrow();
            // The band is the INSTANCE's ordering block (§7), stamped by
            // the host. A plugin passing its own would be ranking itself
            // above the order its document declared.
            let band = e.order.get("band").as_int().unwrap_or(0);
            for b in e.bindings.iter() {
                if b.point != point {
                    continue;
                }
                let mut b = b.clone();
                b.band = band;
                out.push(b);
            }
        }
        Ok(out)
    }

    fn pointspec(&self, point: &str, want: &str) -> Result<Value, PluginError> {
        if !self.0.points.has(point) {
            return fail(
                "plugin_point_unknown",
                &format!("no such point: {}", point),
                details(&[("point", Value::str(point))]),
            );
        }
        let spec = self.0.points.get(point);
        let kind = spec.get("kind");
        if "hook" == want {
            // A point with no declared kind is a hook, which is what makes
            // `{}` the minimal point declaration.
            if !kind.is_null() && kind.as_str() != Some("hook") {
                return fail(
                    "plugin_point_kind",
                    &format!("point is not a hook: {}", point),
                    details(&[("point", Value::str(point)), ("kind", kind)]),
                );
            }
            return Ok(spec);
        }
        if kind.as_str() != Some(want) {
            return fail(
                "plugin_point_kind",
                &format!("point is not a {}: {}", want, point),
                details(&[("point", Value::str(point)), ("kind", kind)]),
            );
        }
        Ok(spec)
    }

    pub fn emit(&self, point: &str, arg: &Value) -> Result<Value, PluginError> {
        let spec = self.pointspec(point, "hook")?;
        let mode = spec.get("mode");
        let mode = mode.as_str().unwrap_or("emit");
        point_emit(&self.bound(point)?, mode, arg)
    }

    pub fn call(&self, point: &str, args: &[Value]) -> Result<Value, PluginError> {
        let spec = self.pointspec(point, "chain")?;
        let base: NextFn = match spec.get("base") {
            Value::Opaque(o) => match o.downcast_ref::<NextFn>() {
                Some(f) => f.clone(),
                None => Rc::new(|a: &[Value]| Ok(a.first().cloned().unwrap_or(Value::Null))),
            },
            _ => Rc::new(|a: &[Value]| Ok(a.first().cloned().unwrap_or(Value::Null))),
        };
        compose(&self.bound(point)?, base)(args)
    }

    pub fn provider(&self, point: &str, args: &[Value]) -> Result<Value, PluginError> {
        let spec = self.pointspec(point, "provider")?;
        let pick = point_provider(&self.bound(point)?, &spec)?;
        match pick.winner {
            None => Ok(spec.get("default")),
            Some(w) => (w.func)(None, args),
        }
    }

    /// The losers are VISIBLE rather than silently ignored (§6.3).
    pub fn shadowed(&self, point: &str) -> Result<Vec<String>, PluginError> {
        if !self.0.points.has(point) {
            return Ok(Vec::new());
        }
        let spec = self.0.points.get(point);
        Ok(point_provider(&self.bound(point)?, &spec)?.shadowed)
    }

    pub fn exports(&self, spec: &str) -> Result<Value, PluginError> {
        let mut all: Vec<Exported> = Vec::new();
        for (eref, entry) in self.0.inst.borrow().iter() {
            let e = entry.borrow();
            // Exports of a `loaded` (not live) instance are VISIBLE (§11).
            if "declared" == e.status || "failed" == e.status {
                continue;
            }
            for (key, value) in e.exports.iter() {
                all.push(Exported {
                    eref: eref.clone(),
                    key: key.clone(),
                    value: value.clone(),
                });
            }
        }
        resolve_export(spec, &all)
    }

    /// The live providers of a capability, best-first (§11.1).
    pub fn capability(&self, name: &str) -> Vec<String> {
        let mut cands: Vec<Value> = Vec::new();
        for (eref, entry) in self.0.inst.borrow().iter() {
            let e = entry.borrow();
            if "live" != e.status {
                continue;
            }
            for prov in e.provides.iter() {
                if prov.get("name").as_str() != Some(name) {
                    continue;
                }
                let mut cand = Value::map();
                cand.set("ref", Value::str(eref));
                cand.set("pos", Value::Num(e.pos));
                cand.set("provides", prov.clone());
                cands.push(cand);
            }
        }
        let mut req = Value::map();
        req.set("name", Value::str(name));
        resolve_capability(&req, &cands)
            .iter()
            .map(|c| c.get("ref").as_str().unwrap_or("").to_string())
            .collect()
    }

    // --- documents --------------------------------------------------

    /// §9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
    /// changed, and move activation state to match", with the stated
    /// ordering - "deactivations and unloads first (reverse load order),
    /// then loads, then activations in load order".
    ///
    /// FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
    /// document once, which never looked at instances the new document had
    /// DROPPED - so an integration removed from a config reload stayed live
    /// with its bindings and resources.
    pub fn apply(&self, doc: &Value, profile: &Value) -> Result<(), PluginError> {
        self.guard()?;
        let profile = if profile.is_null() {
            self.0.opts.get("profile")
        } else {
            profile.clone()
        };

        let mut input = Value::map();
        input.set("doc", doc.clone());
        input.set("profile", profile.clone());
        input.set("keys", self.0.opts.get("keys"));
        input.set("reserved", self.0.reserved.clone());
        let norm = normalize_config(&input)?;

        let want: Vec<String> = norm
            .get("order")
            .as_list()
            .cloned()
            .unwrap_or_default()
            .iter()
            .map(|r| r.as_str().unwrap_or("").to_string())
            .collect();

        let defaults = self.0.opts.get("defaults");
        let mut optionsof: BTreeMap<String, Value> = BTreeMap::new();
        for eref in want.iter() {
            let mut oin = Value::map();
            oin.set("ref", Value::str(eref));
            oin.set("doc", doc.clone());
            oin.set("profile", profile.clone());
            oin.set("shape", self.shapeof(eref));
            oin.set("hostdefaults", defaults.get(&refname(eref)));
            optionsof.insert(eref.clone(), resolve_options(&oin)?);
        }

        // Should this ref be LIVE after the apply? False for a ref the
        // document declares lazy or inactive AND for one it does not name
        // at all - which is what makes "unload what is gone" and "unload
        // what was toggled off" one rule rather than two.
        let instances = norm.get("instance");
        let wantlive = |eref: &str| -> bool {
            let ent = instances.get(eref);
            !ent.is_null()
                && ent.get("active").truthy()
                && ent.get("start").as_str() == Some("eager")
        };

        // --- phase 1: deactivations and unloads, REVERSE load order ----
        let mut drop: Vec<(String, f64)> = Vec::new();
        for (eref, entry) in self.0.inst.borrow().iter() {
            if "declared" == entry.borrow().status || wantlive(eref) {
                continue;
            }
            drop.push((eref.clone(), entry.borrow().pos));
        }
        // Highest `pos` first, ref-descending for a tie, so a consumer
        // declared after its provider goes down first.
        drop.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.0.cmp(&a.0))
        });
        for (eref, _) in drop.iter() {
            self.unload(&Value::str(eref))?;
        }

        // --- phase 2: declare and patch EVERYTHING, in load order ------
        for eref in want.iter() {
            let ent = instances.get(eref);
            let mut spec = Value::map();
            spec.set("options", optionsof[eref].clone());
            spec.set("order", ent.get("order"));
            spec.set("pos", ent.get("pos"));
            let entry = self.declare(&Value::str(eref), &spec)?;
            let mut e = entry.borrow_mut();
            // The bar is REASSERTED ON EVERY APPLY, in both directions - a
            // document that turns the instance back on clears it, which is
            // the whole point of a config switch.
            e.barred = !ent.get("active").truthy();
            // REPLACE rather than refill: a rust callback holds the `Inst`
            // and reads `options` back through the entry every time, so
            // there is no captured map to keep in sync.
            e.options = optionsof[eref].clone();
            e.order = ent.get("order");
            e.pos = ent.get("pos").as_num().unwrap_or(0.0);
        }

        // --- phase 3: loads, in load order -----------------------------
        // ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy
        // instances is twenty map entries and no executed code" (§9.6).
        for eref in want.iter() {
            if wantlive(eref) {
                self.load(&Value::str(eref), &Value::map())?;
            }
        }

        // --- phase 4: activations, in load order -----------------------
        for eref in want.iter() {
            if wantlive(eref) {
                self.activate(&Value::str(eref))?;
            }
        }
        Ok(())
    }

    fn shapeof(&self, eref: &str) -> Value {
        match self.0.catalog.borrow().get(&refname(eref)) {
            Some(d) => d.shape.clone(),
            None => Value::Null,
        }
    }

    pub fn options(&self, eref: &Value, patch: &Value) -> Result<(), PluginError> {
        self.guard()?;
        let entry = self.need(eref)?;
        let (myref, previous, status) = {
            let e = entry.borrow();
            (e.eref.clone(), e.options.clone(), e.status.clone())
        };

        let mut merged = previous.clone();
        for k in patch.keys() {
            merged.set(&k, patch.get(&k));
        }
        let mut input = Value::map();
        input.set("ref", Value::str(&myref));
        input.set("shape", self.shapeof(&myref));
        input.set("doc", Value::map());
        input.set("patch", merged);
        let resolved = resolve_options(&input)?;
        entry.borrow_mut().options = resolved;

        if "live" != status {
            return Ok(());
        }

        let reconfigure = entry.borrow().def.reconfigure.clone();
        match reconfigure {
            Some(func) => {
                self.0.transition.set(true);
                let inst = Inst::new(self.clone(), entry.clone())?;
                let now = entry.borrow().options.clone();
                let outcome = func(&inst, &now, &previous);
                self.0.transition.set(false);
                outcome
            }
            None => {
                // Always correct and sometimes expensive; `reconfigure`
                // exists to make the common case cheap (§9.4).
                self.deactivate(&Value::str(&myref))?;
                self.activate(&Value::str(&myref))?;
                Ok(())
            }
        }
    }

    pub fn close(&self) -> Result<(), PluginError> {
        // A bulk teardown removing the holders too, so `hold` is suspended
        // for exactly those holders (§11.3) - while the consumers-first
        // cascade still runs, which is the half that matters.
        self.0.coordinated.set(true);
        let refs: Vec<String> = self.0.inst.borrow().keys().rev().cloned().collect();
        let mut outcome = Ok(());
        for eref in refs.iter() {
            if self.0.inst.borrow().contains_key(eref) {
                if let Err(e) = self.unload(&Value::str(eref)) {
                    outcome = Err(e);
                    break;
                }
            }
        }
        self.0.coordinated.set(false);
        outcome
    }

    /// The same record §6.6 gives a plugin about itself, reachable from
    /// outside for the corpus.
    pub fn positionof(&self, eref: &str, point: Option<&str>) -> Result<Value, PluginError> {
        let myref = canon(eref);
        let entry = self.0.inst.borrow().get(&myref).cloned();
        if entry.is_none() {
            return fail(
                "plugin_not_loaded",
                &format!("no such instance: {}", eref),
                details(&[("ref", Value::str(eref))]),
            );
        }
        let ranked = self.order(point)?;
        let index = ranked.iter().position(|r| *r == myref);
        let index = index.map(|i| i as i64).unwrap_or(-1);
        let mut out = Value::map();
        out.set("index", Value::Num(index as f64));
        out.set("count", Value::Num(ranked.len() as f64));
        // §6.2 composes b1(b2(b3(base))) with the FIRST binding OUTERMOST,
        // so these are not index 0 and index count-1 the other way round.
        out.set("outermost", Value::Bool(0 == index));
        out.set(
            "innermost",
            Value::Bool(index == ranked.len() as i64 - 1),
        );
        Ok(out)
    }
}

// ---------------------------------------------------------------------
// Inst - what a definition's callbacks see
// ---------------------------------------------------------------------
//
// Deliberately not the internal record: a plugin that could reach `status`
// could also write it.

#[derive(Clone)]
pub struct Inst {
    pub host: Host,
    pub entry: Rc<RefCell<Entry>>,
    pub eref: String,
    pub name: String,
    pub tag: String,
}

impl Inst {
    pub fn new(host: Host, entry: Rc<RefCell<Entry>>) -> Result<Inst, PluginError> {
        let eref = entry.borrow().eref.clone();
        let parsed = parse_ref(&Value::str(&eref))?;
        Ok(Inst {
            host,
            entry,
            name: parsed.get("name").as_str().unwrap_or("").to_string(),
            tag: parsed.get("tag").as_str().unwrap_or("").to_string(),
            eref,
        })
    }

    /// The resolved options, READ FRESH. `apply` and `options` replace the
    /// map wholesale, so a callback that cached this at `define` would
    /// hold the values a later document already changed.
    pub fn options(&self) -> Value {
        self.entry.borrow().options.clone()
    }

    pub fn state(&self) -> Value {
        self.entry.borrow().state.clone()
    }

    pub fn state_get(&self, key: &str) -> Value {
        self.entry.borrow().state.get(key)
    }

    pub fn state_set(&self, key: &str, value: Value) {
        self.entry.borrow_mut().state.set(key, value);
    }

    /// Foreign resources the host did not hand out are registered
    /// explicitly (§8.3); host calls are recorded automatically.
    ///
    /// SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
    /// resources CURRENTLY HELD, so an entry that is registered and then
    /// unwound must leave the count where it found it.
    pub fn release(
        &self,
        func: Rc<dyn Fn() -> Result<(), PluginError>>,
    ) -> Result<(), PluginError> {
        // §8.3: "`inst.release` outside `activate` is
        // `plugin_release_scope`". A flag saying merely that a transition
        // is running is true in `define` too, and a scope entry registered
        // there is never unwound.
        if "activate" != self.host.phase() {
            return fail(
                "plugin_release_scope",
                "release called outside activate",
                Value::Null,
            );
        }
        let host = self.host.clone();
        let done = Cell::new(false);
        let entry = Rc::new(move || {
            if done.get() {
                return Ok(());
            }
            done.set(true);
            host.open_dec();
            func()
        });
        self.entry.borrow_mut().scope.push(entry);
        self.host.open_inc();
        Ok(())
    }

    /// The synthetic counter the driver owns, so "what is open" is data
    /// rather than an assertion each port words differently.
    ///
    /// Returns its own release, so a plugin can hand one back early. The
    /// scope still holds the entry and unwinding it twice is a no-op -
    /// releasing early must not make teardown wrong.
    pub fn acquire(&self) -> Result<ScopeFn, PluginError> {
        // §8.1: resources are "acquired during `activate` - the scope's
        // actual job". Same reason as `release` above.
        if "activate" != self.host.phase() {
            return fail(
                "plugin_release_scope",
                "acquire called outside activate",
                Value::Null,
            );
        }
        let host = self.host.clone();
        let done = Cell::new(false);
        let rel: ScopeFn = Rc::new(move || {
            if done.get() {
                return Ok(());
            }
            done.set(true);
            host.open_dec();
            Ok(())
        });
        self.entry.borrow_mut().scope.push(rel.clone());
        self.host.open_inc();
        Ok(rel)
    }

    /// Bind into a host point. Declared in `define`; the host inserts it
    /// only after `activate` returns successfully (§8.1), which is why a
    /// failing activate leaves no live binding behind.
    pub fn bind(
        &self,
        point: &str,
        func: super::point::BindFn,
        band: &Value,
    ) -> Result<(), PluginError> {
        // §12 has carried `plugin_bind_scope` - "binding declared outside
        // `define`" - since before anything raised it. §8.1 puts binding
        // DECLARATION in `define` and INSERTION at a successful activate,
        // and the guard was the half nobody wrote.
        if "define" != self.host.phase() {
            return fail(
                "plugin_bind_scope",
                &format!("bind called outside define: {}", point),
                details(&[
                    ("ref", Value::str(&self.eref)),
                    ("point", Value::str(point)),
                ]),
            );
        }
        if !self.host.haspoint(point) {
            return fail(
                "plugin_point_unknown",
                &format!("no such point: {}", point),
                details(&[("point", Value::str(point))]),
            );
        }
        self.entry.borrow_mut().bindings.push(Bound {
            eref: self.eref.clone(),
            point: point.to_string(),
            func,
            band: band.as_int().unwrap_or(0),
        });
        Ok(())
    }

    /// Published for other plugins and for the application (§11).
    pub fn export(&self, key: &str, value: Value) {
        self.entry
            .borrow_mut()
            .exports
            .insert(key.to_string(), value);
    }

    /// What this instance can do for others (§11.1).
    pub fn provides(&self, prov: Value) {
        self.entry.borrow_mut().provides.push(prov);
    }

    /// Where this binding landed (§6.6) - the plugin-side counterpart to a
    /// host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact
    /// available.
    pub fn position(&self, point: Option<&str>) -> Result<Value, PluginError> {
        self.host.positionof(&self.eref, point)
    }

    /// AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS THE
    /// INNER ONE'S LIFETIME. Registering the teardown in the instance
    /// scope is what makes that true rather than aspirational.
    pub fn nest(&self, nestopts: &Value) -> Result<Host, PluginError> {
        if !self.host.intransition() {
            return fail(
                "plugin_release_scope",
                "nest called outside a lifecycle callback",
                Value::Null,
            );
        }
        let inner = Host::new(nestopts);
        let closing = inner.clone();
        self.entry
            .borrow_mut()
            .scope
            .push(Rc::new(move || closing.close()));
        self.entry.borrow_mut().inner = Some(inner.clone());
        Ok(inner)
    }
}
