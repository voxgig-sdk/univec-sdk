// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/host.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The host: the lifecycle state machine (§5), extension points (§6),
 * and resource capture (§8). See host.hpp for the two rules that shape
 * every method here. */

#include "host.hpp"

#include <algorithm>

#include "capability.hpp"
#include "config.hpp"
#include "depend.hpp"
#include "export.hpp"
#include "graph.hpp"
#include "order.hpp"
#include "ref.hpp"

namespace plugin {

/* ------------------------------------------------------------------ */
/* construction and registry helpers                                   */
/* ------------------------------------------------------------------ */

Host::Host(const HostOptions& opts)
    : catalog_(opts.catalog ? opts.catalog : makecatalog()),
      reserved_(opts.reserved),
      keys_(opts.keys),
      defaults_(opts.defaults),
      profile_(opts.profile),
      points_(ismap(opts.points) ? opts.points : vmap()),
      bases_(opts.bases),
      dependency_(opts.dependency.empty() ? "restart" : opts.dependency) {}

HostPtr makehost(const HostOptions& opts) { return std::make_shared<Host>(opts); }

InstPtr Host::find(const std::string& ref) const {
  for (const auto& e : instances_) {
    if (e->ref_ == ref) return e;
  }
  return nullptr;
}

/* Every instance ref, SORTED — the deterministic walk §4 rule 4
 * requires in a language whose containers have no inherent order. */
std::vector<std::string> Host::sortedrefs() const {
  std::vector<std::string> refs;
  refs.reserve(instances_.size());
  for (const auto& e : instances_) refs.push_back(e->ref_);
  std::sort(refs.begin(), refs.end());
  return refs;
}

/* ------------------------------------------------------------------ */
/* observation                                                         */
/* ------------------------------------------------------------------ */

V Host::list() const {
  V out = vmap();
  for (const auto& r : sortedrefs()) set(out, r, vstr(find(r)->status_));
  return out;
}

InstPtr Host::instance(const std::string& ref) const {
  /* The VALIDATING canonicalizer, not the forgiving one: a lookup with
   * a malformed ref is `plugin_bad_name`, not a miss
   * (`declare/lookup#malformed`). Rust and swift both wrote this with
   * `canon` and failed that entry. */
  return find(canonref(ref));
}

V Host::observable(const V& result, bool hasresult) const {
  V out = vmap();
  set(out, "status", list());
  set(out, "open", vnum(open_));
  V lg = vlist();
  for (size_t i = 0; i < len(log_); i++) push(lg, at(log_, i));
  set(out, "log", lg);
  set(out, "result", (!hasresult || !result) ? vnull() : result);
  return out;
}

std::string Inst::name() const { return refname(ref_); }

std::string Inst::tag() const {
  size_t cut = ref_.find('$');
  return std::string::npos == cut ? "" : ref_.substr(cut + 1);
}

/* ------------------------------------------------------------------ */
/* guards                                                              */
/* ------------------------------------------------------------------ */

void Host::guard() const {
  if (intransition_) {
    fail("plugin_reentrant",
         "transition attempted from inside a lifecycle callback");
  }
}

InstPtr Host::need(const std::string& ref) const {
  const std::string r = canonref(ref);
  InstPtr e = find(r);
  if (!e) {
    fail("plugin_not_loaded", "no such instance: " + r,
         details1("ref", vstr(r)));
  }
  return e;
}

void Host::checkreserved(const std::string& ref) const {
  if (!islist(reserved_) || 0 == len(reserved_)) return;
  const std::string name = refname(ref);
  for (size_t i = 0; i < len(reserved_); i++) {
    if (isstr(at(reserved_, i)) && asstr(at(reserved_, i)) == name) {
      fail("plugin_ref_reserved", "ref is reserved by the host: " + ref,
           details1("ref", vstr(ref)));
    }
  }
}

/* ------------------------------------------------------------------ */
/* scope                                                               */
/* ------------------------------------------------------------------ */

/* A selection belongs to ONE activation (§11.4). Leaving `live` by any
 * door drops it, so the next activation ranks afresh — keeping it would
 * make a consumer prefer a provider it never actually ran against.
 *
 * Returns the errors the scope raised. §8.3: "A failing release does
 * not stop the rest. Every entry runs, in reverse order, whatever any
 * of them does; the errors are collected and raised as one
 * `plugin_release_failed`." */
V Host::unwind(const InstPtr& e) {
  e->selected_ = vmap();
  V errors = vlist();
  for (size_t k = e->scope_.size(); 0 < k; k--) {
    AcquireHandle s = e->scope_[k - 1];
    if (s->done) continue;
    s->done = true;
    if (s->counts) open_ -= 1;
    if (!s->fn) continue;
    try {
      s->fn();
    }
    catch (const PluginError& err) {
      push(errors, vstr(err.message));
    }
  }
  e->scope_.clear();
  return errors;
}

/* §8.3: "A failed release ends the instance in `failed`, exactly as a
 * failed callback does (§5.2) — a release that raised may have leaked,
 * and an instance that may be holding resources it cannot account for
 * must not be reactivated." */
void Host::releasecheck(const InstPtr& e, const V& errors) {
  if (0 == len(errors)) return;
  e->status_ = "failed";
  std::string why;
  for (size_t i = 0; i < len(errors); i++) {
    if (0 < i) why += "; ";
    why += asstr(at(errors, i));
  }
  V d = vmap();
  set(d, "ref", vstr(e->ref_));
  set(d, "cause", errors);
  fail("plugin_release_failed", "release failed for " + e->ref_ + ": " + why, d);
}

/* ------------------------------------------------------------------ */
/* the instance api                                                    */
/* ------------------------------------------------------------------ */

AcquireHandle Inst::acquire() {
  /* §8.1: resources are "acquired during `activate` — the scope's
   * actual job". */
  if ("activate" != owner_->phase_) {
    fail("plugin_release_scope", "acquire called outside activate");
  }
  auto s = std::make_shared<ScopeEntry>();
  scope_.push_back(s);
  owner_->open_ += 1;
  return s;
}

/* Hand a resource back before teardown. Idempotent, and the scope keeps
 * the entry: unwinding it again must be a no-op, or releasing early
 * would make teardown wrong. */
void Inst::giveback(const AcquireHandle& handle) {
  if (!handle || handle->done) return;
  handle->done = true;
  if (handle->counts) owner_->open_ -= 1;
}

void Inst::release(Release fn) {
  /* §8.3: "`inst.release` outside `activate` is `plugin_release_scope`".
   * Being in a transition is true in `define` too, and a scope entry
   * registered there is never unwound — `unload` on a merely `loaded`
   * instance does not unwind, because a loaded instance is not supposed
   * to hold anything. */
  if ("activate" != owner_->phase_) {
    fail("plugin_release_scope", "release called outside activate");
  }
  /* SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
   * resources CURRENTLY HELD, so an entry that is registered and then
   * unwound must leave the count where it found it. Incrementing on
   * registration and never decrementing made every `release` a
   * permanent leak in the counter. */
  auto s = std::make_shared<ScopeEntry>();
  s->fn = std::move(fn);
  scope_.push_back(s);
  owner_->open_ += 1;
}

void Inst::bind(const std::string& point, Hook hook, ChainFn chain,
                const V& band) {
  Host* h = owner_;
  /* §12's `plugin_bind_scope`: "binding declared outside `define`". §8.1
   * puts binding declaration in `define` and insertion at a SUCCESSFUL
   * activate, and the guard was the half that never got written — so a
   * binding added from `activate` went live without being part of the
   * loaded definition, and a deactivate/activate cycle appended it
   * again. The code was in the table before anything raised it. */
  if ("define" != h->phase_) {
    V d = vmap();
    set(d, "ref", vstr(ref_));
    set(d, "point", vstr(point));
    fail("plugin_bind_scope", "bind called outside define: " + point, d);
  }
  if (!has(h->points_, point)) {
    fail("plugin_point_unknown", "no such point: " + point,
         details1("point", vstr(point)));
  }

  Bound b;
  b.ref = ref_;
  b.point = point;
  b.band = isnum(band) ? asnum(band) : 0.0;
  b.hook = std::move(hook);
  b.chain = std::move(chain);
  bindings_.push_back(std::move(b));
}

void Inst::bindhook(const std::string& point, Hook hook, const V& band) {
  bind(point, std::move(hook), nullptr, band);
}

void Inst::bindchain(const std::string& point, ChainFn chain, const V& band) {
  bind(point, nullptr, std::move(chain), band);
}

void Inst::exportvalue(const std::string& key, const V& value) {
  set(exports_, key, value);
}

void Inst::provides(const V& p) { push(provides_, p); }

HostPtr Inst::nest(const HostOptions& opts) {
  if (!owner_->intransition_) {
    fail("plugin_release_scope", "nest called outside a lifecycle callback");
  }
  /* AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS THE
   * INNER ONE'S LIFETIME. Registering the teardown in the instance
   * scope is what makes that true rather than aspirational: the inner
   * host closes when the outer instance deactivates, in the same
   * reverse unwind as every other resource.
   *
   * It does NOT count toward `open` — a teardown is not an acquisition
   * (`nest/open`). */
  HostPtr inner = makehost(opts);
  auto s = std::make_shared<ScopeEntry>();
  s->counts = false;
  s->fn = [inner]() { inner->close(); };
  scope_.push_back(s);
  inner_ = inner;
  return inner;
}

V Inst::position(const std::string& point) const {
  return owner_->positionof(ref_, point);
}

/* ------------------------------------------------------------------ */
/* running a callback                                                  */
/* ------------------------------------------------------------------ */

/* Restores `intransition` and `phase` however the callback leaves —
 * return or throw. In c this is two assignments repeated on both paths;
 * here it is the destructor's job, which is the point of having one. */
namespace {
struct PhaseGuard {
  bool* intransition;
  std::string* phase;
  PhaseGuard(bool* t, std::string* p, const std::string& at)
      : intransition(t), phase(p) {
    *intransition = true;
    *phase = at;
  }
  ~PhaseGuard() {
    *intransition = false;
    phase->clear();
  }
};
}  // namespace

void Host::run(const InstPtr& e, const std::string& at) {
  const Lifecycle* fn = definitioncallback(e->def_, at);

  push(log_, vstr(e->ref_ + ":" + at));

  V ev = vmap();
  set(ev, "ref", vstr(e->ref_));
  set(ev, "event", vstr(at));
  set(ev, "seq", vnum(e->seq_));
  set(ev, "status", vstr(e->status_));
  push(events_, ev);

  if (nullptr == fn || !*fn) return;

  try {
    PhaseGuard g(&intransition_, &phase_, at);
    (*fn)(*e);
  }
  catch (const PluginError& err) {
    /* §12: `plugin_define_failed` and its three siblings are "a callback
     * raised; wraps the cause". AN ERROR THAT ALREADY CARRIES A CODE
     * KEEPS IT — the code is the error's identity, and a plugin that
     * raised `store_unreachable` must not have it rewritten. Only a
     * code-less error is wrapped, which is the ordinary case for a
     * callback that let a library error escape. */
    if (!err.code.empty() && "plugin_bare" != err.code) throw;
    V d = vmap();
    set(d, "ref", vstr(e->ref_));
    set(d, "cause", vstr(err.text));
    fail("plugin_" + at + "_failed",
         e->ref_ + " raised in " + at + ": " + err.text, d);
  }
}

/* ------------------------------------------------------------------ */
/* requirements and providers                                          */
/* ------------------------------------------------------------------ */

V Host::providersof(const V& req) const {
  V cands = vlist();
  /* ASK WHETHER THE NAME IS A REF, do not assume it. A requirement name
   * is a CAPABILITY name first (§11.1) and capability names are
   * free-form, so `2fa` and `my cap` are legal ones that no ref could
   * be called — and `canonref` RAISES on those, which made a perfectly
   * legal document kill the host right here. */
  V rname = get(req, "name");
  std::string asref;
  bool isaref = isstr(rname) && tryref(asstr(rname), asref);

  for (const auto& r : sortedrefs()) {
    InstPtr t = find(r);
    if ("live" != t->status_) continue;
    /* A ref satisfies directly. */
    if (isaref && r == asref) {
      V prov = vmap();
      set(prov, "name", rname);
      V c = vmap();
      set(c, "ref", vstr(r));
      set(c, "pos", vnum(t->pos_));
      set(c, "provides", prov);
      push(cands, c);
      continue;
    }
    for (size_t j = 0; j < len(t->provides_); j++) {
      V p = at(t->provides_, j);
      if (same(get(p, "name"), rname)) {
        V c = vmap();
        set(c, "ref", vstr(r));
        set(c, "pos", vnum(t->pos_));
        set(c, "provides", p);
        push(cands, c);
      }
    }
  }
  return resolvecapability(req, cands);
}

V Host::unmetof(const InstPtr& e) const {
  V out = vlist();
  V reqs = requirements(e->options_);
  for (size_t i = 0; i < len(reqs); i++) {
    V r = at(reqs, i);
    if (!gatesactivation(r)) continue;
    if (0 == len(providersof(r))) push(out, get(r, "name"));
  }
  return out;
}

/* §11.4's always-reluctant selection, and the ONE place a provider is
 * chosen for a live instance. "A satisfied requirement is not re-bound
 * while it stays satisfied" is a statement about a REMEMBERED choice.
 *
 * `remember` is false for the questions asked ABOUT an instance rather
 * than BY it — introspection must not create a binding. */
std::string Host::chosen(const InstPtr& e, const V& req, bool remember) const {
  V cands = providersof(req);
  if (0 == len(cands)) return "";
  const std::string name = asstr(get(req, "name"));
  V heldv = get(e->selected_, name);
  if (isstr(heldv)) {
    for (size_t i = 0; i < len(cands); i++) {
      if (asstr(get(at(cands, i), "ref")) == asstr(heldv)) return asstr(heldv);
    }
  }
  const std::string first = asstr(get(at(cands, 0), "ref"));
  if (remember) set(e->selected_, name, vstr(first));
  return first;
}

/* The instance currently SELECTED for each of this one's
 * restart-causing requirements. A BINDING IS TO AN INSTANCE, not to a
 * capability (§11.1): the selected one going away restarts a `static`
 * consumer even though a survivor is available. */
V Host::boundproviders(const InstPtr& e) const {
  V out = vlist();
  V reqs = requirements(e->options_);
  for (size_t i = 0; i < len(reqs); i++) {
    V r = at(reqs, i);
    if (!restartsonloss(r)) continue;
    const std::string ref = chosen(e, r, false);
    if (ref.empty()) continue;
    bool dup = false;
    for (size_t j = 0; j < len(out); j++) {
      if (asstr(at(out, j)) == ref) { dup = true; break; }
    }
    if (!dup) push(out, vstr(ref));
  }
  return out;
}

V Host::consumersof(const std::string& ref) const {
  V out = vlist();
  for (const auto& r : sortedrefs()) {
    if (r == ref) continue;
    InstPtr c = find(r);
    if ("live" != c->status_) continue;
    V bp = boundproviders(c);
    for (size_t j = 0; j < len(bp); j++) {
      if (asstr(at(bp, j)) == ref) { push(out, vstr(r)); break; }
    }
  }
  return out;
}

/* §11.3's `hold` asks a DIFFERENT question from the cascade.
 *
 * The cascade wants the edges that RESTART — mandatory-static and
 * optional-static. `hold` says "deactivating a REQUIRED instance is
 * `plugin_dependency_held`", and `required` is CARDINALITY:
 * `gatesactivation`, not `restartsonloss`. The two sets differ in both
 * directions and each difference was a real bug. */
V Host::holdersof(const std::string& ref) const {
  V out = vlist();
  for (const auto& r : sortedrefs()) {
    if (r == ref) continue;
    InstPtr c = find(r);
    if ("live" != c->status_) continue;
    V reqs = requirements(c->options_);
    for (size_t j = 0; j < len(reqs); j++) {
      V req = at(reqs, j);
      if (!gatesactivation(req)) continue;
      if (chosen(c, req, false) == ref) { push(out, vstr(r)); break; }
    }
  }
  return out;
}

/* The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
 * TEARDOWN. In a bulk operation that is removing the holders too, it is
 * suspended — otherwise `close()` under `hold` would raise on the first
 * provider it reached whenever a document happened to list a consumer
 * after it, which is the policy refusing the one teardown it has no
 * reason to object to. */
void Host::held(const InstPtr& e) const {
  if ("hold" != dependency_) return;
  if (coordinated_) return;
  V holders = holdersof(e->ref_);
  if (0 == len(holders)) return;
  V d = vmap();
  set(d, "ref", vstr(e->ref_));
  set(d, "holders", holders);
  fail("plugin_dependency_held",
       "instance is required by live consumers: " + e->ref_, d);
}

/* The requirement graph as plain data, for the pure detector. */
V Host::graphnodes() const {
  V out = vlist();
  for (const auto& r : sortedrefs()) {
    InstPtr e = find(r);
    V provides = vlist();
    for (size_t j = 0; j < len(e->provides_); j++) {
      push(provides, get(at(e->provides_, j), "name"));
    }
    V node = vmap();
    set(node, "ref", vstr(r));
    set(node, "provides", provides);
    set(node, "requires", requirements(e->options_));
    push(out, node);
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* ordering and points                                                 */
/* ------------------------------------------------------------------ */

V Host::order(const std::string& point) const {
  /* Sorted by declaration SEQUENCE, which is what makes the §7 sort's
   * fall-through deterministic in a language whose containers have no
   * insertion order. §7 breaks ties by `pos`; two instances CAN share
   * one — `declare` defaults `pos` to the registry size, so an unload
   * followed by a fresh declare reuses a surviving instance's — and
   * past that the canonical was falling through to map order. `seq` is
   * that order, made explicit. Found by review of the go port. */
  std::vector<InstPtr> live;
  for (const auto& e : instances_) {
    if ("live" == e->status_) live.push_back(e);
  }
  std::sort(live.begin(), live.end(),
            [](const InstPtr& a, const InstPtr& b) { return a->seq_ < b->seq_; });

  V bindings = vlist();
  for (const auto& e : live) {
    V b = vmap();
    set(b, "ref", vstr(e->ref_));
    set(b, "pos", vnum(e->pos_));
    if (!isnull(e->order_)) set(b, "order", e->order_);
    push(bindings, b);
  }

  V spec = point.empty() ? nullptr : get(points_, point);
  return resolveorder(bindings, ismap(spec) ? get(spec, "pin") : nullptr);
}

V Host::positionof(const std::string& ref, const std::string& point) const {
  V ranked = order(point);
  const std::string r = canonref(ref);
  double index = -1;
  for (size_t i = 0; i < len(ranked); i++) {
    if (asstr(at(ranked, i)) == r) { index = static_cast<double>(i); break; }
  }
  V out = vmap();
  set(out, "index", vnum(index));
  set(out, "count", vnum(static_cast<double>(len(ranked))));
  /* §6.2 composes b1(b2(b3(base))) with the FIRST binding OUTERMOST, so
   * these are not index 0 and count-1 the other way round. Getting this
   * backwards is the exact error the positional pin vocabulary exists
   * to prevent. */
  set(out, "outermost", vbool(0 == index));
  set(out, "innermost", vbool(index == static_cast<double>(len(ranked)) - 1));
  return out;
}

/* Live bindings on a point, in resolved order. Recomputed on any change
 * to the live set (§7) rather than cached at startup — the bug a host
 * discovers only when something deactivates in production. */
std::vector<Bound> Host::boundon(const std::string& point) const {
  V ranked = order(point);
  std::vector<Bound> out;
  for (size_t i = 0; i < len(ranked); i++) {
    InstPtr e = find(asstr(at(ranked, i)));
    if (!e) continue;
    /* The band is the INSTANCE's ordering block (§7), stamped by the
     * host. A plugin passing its own would be ranking itself above the
     * order its document declared. */
    V band = get(e->order_, "band");
    double bandv = isnum(band) ? asnum(band) : 0.0;
    for (const auto& b : e->bindings_) {
      if (b.point != point) continue;
      Bound copy = b;
      copy.band = bandv;
      out.push_back(copy);
    }
  }
  return out;
}

V Host::pointspec(const std::string& point) const {
  if (!has(points_, point)) {
    fail("plugin_point_unknown", "no such point: " + point,
         details1("point", vstr(point)));
  }
  V spec = get(points_, point);
  return ismap(spec) ? spec : vmap();
}

static void checkkind(const V& spec, const std::string& point,
                      const std::string& want) {
  V kind = get(spec, "kind");
  bool given = isstr(kind);
  bool ok = given ? (asstr(kind) == want) : ("hook" == want);
  if (ok) return;
  V d = vmap();
  set(d, "point", vstr(point));
  set(d, "kind", given ? kind : vnull());
  fail("plugin_point_kind", "point is not a " + want + ": " + point, d);
}

V Host::emit(const std::string& point, const V& arg) {
  V spec = pointspec(point);
  checkkind(spec, point, "hook");
  auto bindings = boundon(point);
  V mode = get(spec, "mode");
  const std::string m = isstr(mode) ? asstr(mode) : "emit";
  V errors;
  V out = pointemit(bindings, m, arg, errors);
  if ("emit" == m) return nullptr;
  if ("bail" == m) return out;
  return errors;
}

V Host::call(const std::string& point, const V& arg) {
  V spec = pointspec(point);
  checkkind(spec, point, "chain");
  auto bindings = boundon(point);
  /* The host owns the base and a plugin cannot replace it (§6.2). One
   * that wants to SUBSTITUTE rather than wrap binds innermost and
   * simply does not call `next`. */
  auto it = bases_.find(point);
  return pointcall(bindings, bases_.end() == it ? Hook() : it->second, arg);
}

V Host::provider(const std::string& point, const V& arg) {
  V spec = pointspec(point);
  checkkind(spec, point, "provider");
  auto bindings = boundon(point);
  V shadow;
  long winner = pointprovider(bindings, truthy(get(spec, "exclusive")), shadow);
  if (0 > winner) return get(spec, "default");
  return bindings[static_cast<size_t>(winner)].hook(arg);
}

V Host::trace() const {
  V out = vlist();
  for (size_t i = 0; i < len(events_); i++) push(out, at(events_, i));
  return out;
}

V Host::shadowed(const std::string& point) const {
  if (!has(points_, point)) return vlist();
  V spec = get(points_, point);
  auto bindings = boundon(point);
  V shadow;
  pointprovider(bindings, ismap(spec) && truthy(get(spec, "exclusive")), shadow);
  return shadow ? shadow : vlist();
}

V Host::exports(const std::string& spec) const {
  V all = vlist();
  for (const auto& r : sortedrefs()) {
    InstPtr e = find(r);
    /* Exports of a `loaded` (not live) instance are VISIBLE (§11). */
    if ("declared" == e->status_ || "failed" == e->status_) continue;
    for (const auto& k : keys(e->exports_)) {
      V ex = vmap();
      set(ex, "ref", vstr(r));
      set(ex, "key", vstr(k));
      set(ex, "value", get(e->exports_, k));
      push(all, ex);
    }
  }
  return resolveexport(vstr(spec), all);
}

V Host::capability(const std::string& name) const {
  V cands = vlist();
  for (const auto& r : sortedrefs()) {
    InstPtr e = find(r);
    if ("live" != e->status_) continue;
    for (size_t j = 0; j < len(e->provides_); j++) {
      V p = at(e->provides_, j);
      if (isstr(get(p, "name")) && asstr(get(p, "name")) == name) {
        V c = vmap();
        set(c, "ref", vstr(r));
        set(c, "pos", vnum(e->pos_));
        set(c, "provides", p);
        push(cands, c);
      }
    }
  }
  V req = vmap();
  set(req, "name", vstr(name));
  V ranked = resolvecapability(req, cands);
  V out = vlist();
  for (size_t i = 0; i < len(ranked); i++) push(out, get(at(ranked, i), "ref"));
  return out;
}

/* ------------------------------------------------------------------ */
/* the state machine                                                   */
/* ------------------------------------------------------------------ */

std::string Host::autotag(const std::string& name) const {
  /* AUTO-TAGGING IS EXPLICIT (§4 rule 3): the LOWEST UNUSED POSITIVE
   * INTEGER tag. It needs a host because it must know what is already
   * declared, which is why it cannot live in the pure `ref` section. */
  for (int n = 1;; n++) {
    const std::string cand = formatref(vstr(name), vstr(std::to_string(n)));
    if (!find(cand)) return cand;
  }
}

InstPtr Host::declare(const std::string& ref, const DeclareSpec& spec) {
  std::string r;
  if ("?" == spec.tag) r = autotag(refname(canonref(ref)));
  else r = canonref(ref);

  if (!spec.hostowned) checkreserved(r);

  const std::string defname =
      spec.definition.empty() ? refname(r) : spec.definition;
  DefinitionPtr def = catalog_->get(defname);
  if (!def) {
    fail("plugin_unknown_definition", "not in catalog: " + defname,
         details1("name", vstr(defname)));
  }

  InstPtr existing = find(r);
  if (existing) {
    /* §4 rule 1: a pair addresses at most one instance. Re-declaring the
     * SAME definition is the idempotent case; a different one is a
     * duplicate, not a silent overwrite (seneca) and not an
     * impossibility (sdkgen). */
    if (existing->def_->name != def->name) {
      fail("plugin_ref_duplicate", "instance already declared: " + r,
           details1("ref", vstr(r)));
    }
    return existing;
  }

  auto e = std::make_shared<Inst>();
  e->ref_ = r;
  e->def_ = def;
  e->status_ = "declared";
  e->pos_ = spec.haspos ? spec.pos : static_cast<double>(instances_.size());
  e->seq_ = seqn_++;
  /* NO OPTIONS ADOPTED HERE. `apply` resolves options and hands the map
   * over; adopting the caller's map made target and source THE SAME MAP
   * in the refill that follows, which cleared its own source and left a
   * first-time instance with no options at all. */
  e->options_ = ismap(spec.options) ? spec.options : vmap();
  e->order_ = spec.order;
  e->owner_ = this;
  instances_.push_back(e);
  return e;
}

InstPtr Host::load(const std::string& ref, const DeclareSpec& spec) {
  guard();
  InstPtr e = declare(ref, spec);
  if ("declared" != e->status_) return e;   /* idempotent */
  /* PRESENT AND NOT NULL, not merely present. Every driver builds its
   * command spec with all four keys and a null for each absent one, so
   * a presence test reads an omitted `options` as an authored empty and
   * wipes the real ones. */
  if (ismap(spec.options)) e->options_ = spec.options;

  try {
    run(e, "define");
  }
  catch (const PluginError&) {
    e->status_ = "failed";
    throw;
  }
  e->status_ = "loaded";

  /* AT LOAD, and before anything runs: a cycle through restart-causing
   * requirements does not settle, and the only safe time to report a
   * non-terminating reconcile is before it starts (§11.3). `provides`
   * is populated by `define`, which has just run, so this is the first
   * moment the graph is complete. */
  try {
    checkcycle(graphnodes());
  }
  catch (const PluginError&) {
    e->status_ = "failed";
    throw;
  }
  return e;
}

/* CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).
 *
 * The cascade is part of the provider's own deactivation and runs
 * BEFORE the provider's `deactivate` callback and scope unwind, so a
 * consumer's teardown can still call the thing it depends on — flushing
 * a buffer to the store it is about to lose is exactly what a
 * `deactivate` callback is for. */
void Host::cascade(const InstPtr& provider, const V& seen) {
  if (has(seen, provider->ref_)) return;
  set(seen, provider->ref_, vbool(true));

  V cons = consumersof(provider->ref_);
  for (size_t i = 0; i < len(cons); i++) {
    InstPtr c = find(asstr(at(cons, i)));
    if (!c || "live" != c->status_) continue;
    cascade(c, seen);                       /* deepest-first */
    bool bad = false;
    try {
      run(c, "deactivate");
    }
    catch (const PluginError&) {
      bad = true;
    }
    V errors = unwind(c);
    if (bad || 0 < len(errors)) {
      /* §5.2: ANY failure during a transition lands the instance in
       * `failed`, and a cascaded consumer is not an exception. Marking
       * it `pending` instead handed it straight back to `reconcile`,
       * which would activate it again the moment the provider returned
       * — the one thing `failed` exists to stop. */
      c->status_ = "failed";
      continue;
    }
    c->status_ = "pending";
    c->unmet_ = unmetof(c);
  }
}

InstPtr Host::activate(const std::string& ref) {
  guard();
  InstPtr e = need(ref);
  if ("live" == e->status_) return e;      /* no-op returning success */
  if ("failed" == e->status_) {
    fail("plugin_bad_state", "instance has failed: " + e->ref_,
         details1("ref", vstr(e->ref_)));
  }
  /* §9.6: `active: false` bars the instance from running, and the bar
   * is on the INSTANCE rather than on the apply that set it. `ready`
   * reaches this through `activate`, which is why one guard covers both
   * verbs the design names. */
  if (e->barred_) {
    fail("plugin_inactive", "instance is barred by active: false: " + e->ref_,
         details1("ref", vstr(e->ref_)));
  }
  if ("declared" == e->status_) load(e->ref_, DeclareSpec());

  /* A declared requirement that is not live means `pending`: activation
   * is a STANDING REQUEST, not a one-shot event. */
  V unmet = unmetof(e);
  if (0 < len(unmet)) {
    e->unmet_ = unmet;
    e->status_ = "pending";
    return e;
  }

  try {
    run(e, "activate");
  }
  catch (const PluginError&) {
    /* Unwind whatever the partial activation captured, in reverse. */
    unwind(e);
    e->status_ = "failed";
    throw;
  }

  /* §11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
   * later question — the cascade, `hold`, `unmet` — reads it back
   * rather than re-ranking, which is what "always-reluctant" means. */
  V reqs = requirements(e->options_);
  for (size_t i = 0; i < len(reqs); i++) chosen(e, at(reqs, i), true);
  e->status_ = "live";
  reconcile();
  return e;
}

InstPtr Host::deactivate(const std::string& ref) {
  guard();
  InstPtr e = need(ref);
  if ("loaded" == e->status_ || "declared" == e->status_) return e;

  /* §5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`. Falling
   * through here ran the definition's `deactivate` on an instance that
   * never completed activation and, if that callback happened to
   * succeed, returned it to `loaded` — from where it could be activated
   * again, which is precisely what `failed` exists to prevent. */
  if ("failed" == e->status_) {
    fail("plugin_bad_state", "instance has failed: " + e->ref_,
         details1("ref", vstr(e->ref_)));
  }

  if ("pending" == e->status_) {
    /* DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It never
     * reached activate, so it holds no scope and no live bindings;
     * running the definition's deactivate there would be teardown
     * without matching setup. It cannot fail. */
    e->status_ = "loaded";
    e->unmet_ = vlist();
    return e;
  }

  held(e);
  cascade(e, vmap());

  try {
    run(e, "deactivate");
  }
  catch (const PluginError&) {
    unwind(e);
    e->status_ = "failed";
    throw;
  }
  releasecheck(e, unwind(e));
  e->status_ = "loaded";
  reconcile();
  return e;
}

void Host::unload(const std::string& ref) {
  guard();
  InstPtr e = need(ref);
  if ("live" == e->status_ || "pending" == e->status_) {
    if ("live" == e->status_) {
      held(e);
      cascade(e, vmap());
      try {
        run(e, "deactivate");
      }
      catch (const PluginError&) {
        /* §5.2: ANY failure during a transition lands the instance in
         * `failed`, with the scope STILL FULLY UNWOUND. An earlier
         * draft let the raise propagate straight out of `unload`, which
         * left the instance `live` and its scope untouched — reporting
         * a failure while leaking exactly the resources the failure was
         * about. */
        unwind(e);
        e->status_ = "failed";
        throw;
      }
      releasecheck(e, unwind(e));
    }
    e->status_ = "loaded";
  }

  auto drop = [this, &e]() {
    auto it = std::find(instances_.begin(), instances_.end(), e);
    if (instances_.end() != it) instances_.erase(it);
  };

  if ("loaded" == e->status_ || "failed" == e->status_) {
    try {
      run(e, "close");
    }
    catch (const PluginError&) {
      drop();
      throw;
    }
  }
  drop();
}

InstPtr Host::ready(const std::string& ref) {
  /* Runs the whole forward path in one call (§5.1). §15.2's verb list
   * omits this; §5.1 defines it and §15.3's `declare` row requires the
   * corpus to pin it, so the list was incomplete rather than excluding
   * it (DOCS.md §4.2). */
  guard();
  const std::string r = canonref(ref);
  if (!find(r)) declare(r, DeclareSpec());
  if ("declared" == find(r)->status_) load(r, DeclareSpec());
  return activate(r);
}

/* EAGER reconciliation: run to a fixed point rather than scheduling.
 *
 * Two directions, and both are the reason `pending` exists. Activation
 * is a STANDING REQUEST, not a one-shot event: a pending instance whose
 * requirement arrives activates without being asked again, and a LIVE
 * instance whose requirement is lost goes back to pending —
 * recursively, through its own consumers. */
void Host::reconcile() {
  bool moved = true;
  int rounds = 0;
  while (moved) {
    moved = false;
    if (1000 < ++rounds) break;

    /* Losses first, so a cascade settles in one pass rather than
     * alternating with re-activations. */
    for (const auto& r : sortedrefs()) {
      InstPtr e = find(r);
      if (!e || "live" != e->status_) continue;
      V reqs = requirements(e->options_);
      V lost = vlist();
      for (size_t j = 0; j < len(reqs); j++) {
        V q = at(reqs, j);
        if (!gatesactivation(q)) continue;
        if (0 == len(providersof(q))) push(lost, q);
      }
      if (0 == len(lost)) continue;
      /* POLICY IS PER REQUIREMENT, not per instance (§11.3): only the
       * definition that has the requirement knows what it can cope
       * with, and one instance may hold both a `static` and a `dynamic`
       * one. A `dynamic` requirement whose provider is gone leaves the
       * consumer LIVE and notified. */
      bool anyrestart = false;
      for (size_t j = 0; j < len(lost); j++) {
        if (restartsonloss(at(lost, j))) { anyrestart = true; break; }
      }
      if (!anyrestart) continue;

      bool bad = false;
      try {
        run(e, "deactivate");
      }
      catch (const PluginError&) {
        bad = true;
      }
      V errors = unwind(e);
      if (bad || 0 < len(errors)) {
        e->status_ = "failed";
        moved = true;
        continue;
      }
      e->status_ = "pending";
      e->unmet_ = unmetof(e);
      moved = true;
    }

    for (const auto& r : sortedrefs()) {
      InstPtr e = find(r);
      if (!e || "pending" != e->status_) continue;
      if (0 < len(unmetof(e))) continue;
      try {
        run(e, "activate");
        V reqs = requirements(e->options_);
        for (size_t j = 0; j < len(reqs); j++) chosen(e, at(reqs, j), true);
        e->status_ = "live";
        e->unmet_ = vlist();
        moved = true;
      }
      catch (const PluginError&) {
        unwind(e);
        e->status_ = "failed";
        moved = true;
      }
    }
  }
}

/* ------------------------------------------------------------------ */
/* documents                                                           */
/* ------------------------------------------------------------------ */

/* Empty the target and refill it, so callers holding the reference see
 * the new values. A definition's callbacks close over the options map
 * they were handed at `define`; replacing the reference would leave
 * every binding reading the values the first apply gave it. */
static void refill(const V& target, const V& source) {
  for (const auto& k : keys(target)) del(target, k);
  for (const auto& k : keys(source)) set(target, k, get(source, k));
}

V Host::shapeof(const std::string& ref) const {
  DefinitionPtr d = catalog_->get(refname(ref));
  return d ? d->shape : nullptr;
}

void Host::apply(const V& doc, const V& profile) {
  guard();
  V in = vmap();
  set(in, "doc", doc);
  set(in, "profile", isnull(profile) ? profile_ : profile);
  set(in, "keys", keys_);
  set(in, "reserved", reserved_);
  V norm = normalizeconfig(in);

  V want = get(norm, "order");
  V optionsof = vmap();
  for (size_t i = 0; i < len(want); i++) {
    const std::string ref = asstr(at(want, i));
    V oin = vmap();
    set(oin, "ref", vstr(ref));
    set(oin, "doc", doc);
    set(oin, "profile", isnull(profile) ? profile_ : profile);
    set(oin, "shape", shapeof(ref));
    if (ismap(defaults_)) set(oin, "hostdefaults", get(defaults_, refname(ref)));
    set(optionsof, ref, resolveoptions(oin));
  }

  /* --- phase 1: deactivations and unloads, in REVERSE load order --- */
  V instancespec = get(norm, "instance");
  std::vector<std::string> drop;
  for (const auto& e : instances_) {
    if ("declared" == e->status_) continue;
    V ent = get(instancespec, e->ref_);
    bool wantlive = ismap(ent) && truthy(get(ent, "active")) &&
                    "eager" == asstr(get(ent, "start"));
    if (!wantlive) drop.push_back(e->ref_);
  }
  /* Reverse load order: highest `pos` first, ref-descending for a tie,
   * so a consumer declared after its provider goes down first. */
  std::sort(drop.begin(), drop.end(),
            [this](const std::string& a, const std::string& b) {
              InstPtr x = find(a), y = find(b);
              if (x->pos_ != y->pos_) return x->pos_ > y->pos_;
              return a > b;
            });
  for (const auto& r : drop) unload(r);

  /* --- phase 2: declare and patch EVERYTHING, in load order -------- */
  for (size_t i = 0; i < len(want); i++) {
    const std::string ref = asstr(at(want, i));
    V ent = get(instancespec, ref);
    DeclareSpec spec;
    spec.order = get(ent, "order");
    spec.haspos = true;
    spec.pos = asnum(get(ent, "pos"));
    declare(ref, spec);
    InstPtr e = find(ref);
    /* The bar is REASSERTED ON EVERY APPLY, in both directions — a
     * document that turns the instance back on clears it, which is the
     * whole point of a config switch. */
    e->barred_ = !truthy(get(ent, "active"));
    refill(e->options_, get(optionsof, ref));
    e->order_ = get(ent, "order");
    e->pos_ = asnum(get(ent, "pos"));
  }

  /* --- phase 3: loads, then phase 4: activations, in load order ---- */
  for (int phase = 0; phase < 2; phase++) {
    for (size_t i = 0; i < len(want); i++) {
      const std::string ref = asstr(at(want, i));
      V ent = get(instancespec, ref);
      bool wantlive = truthy(get(ent, "active")) &&
                      "eager" == asstr(get(ent, "start"));
      if (!wantlive) continue;
      if (0 == phase) load(ref, DeclareSpec());
      else activate(ref);
    }
  }
}

void Host::setoptions(const std::string& ref, const V& patch) {
  guard();
  InstPtr e = need(ref);
  V previous = clone(e->options_);
  V in = vmap();
  set(in, "ref", vstr(e->ref_));
  set(in, "shape", shapeof(e->ref_));
  set(in, "doc", vmap());
  set(in, "patch", mergevalue(previous, patch));
  refill(e->options_, resolveoptions(in));

  if ("live" != e->status_) return;
  if (e->def_->reconfigure) {
    PhaseGuard g(&intransition_, &phase_, "reconfigure");
    e->def_->reconfigure(*e, e->options_, previous);
    return;
  }
  /* Always correct and sometimes expensive; `reconfigure` exists to
   * make the common case cheap (§9.4). */
  deactivate(e->ref_);
  activate(e->ref_);
}

void Host::close() {
  /* A bulk teardown removing the holders too, so `hold` is suspended
   * for exactly those holders (§11.3) — while the consumers-first
   * cascade still runs, which is the half that matters. */
  /* A COORDINATED FLAG THAT SURVIVES A RAISE IS A DISABLED GUARD. The
canonical wraps the teardown in `try/finally`; here an unload that
raises would skip the reset and leave the host permanently
`coordinated`, so a caller that catches the error and carries on under
`dependency: "hold"` gets ad-hoc deactivation with the holder check
silently off.

     RAII rather than a try/catch: the flag is cleared by a destructor,
     so it is cleared on the throwing path without the path being
     written down twice. */
  struct Coordinating {
    bool* flag;
    explicit Coordinating(bool* f) : flag(f) { *flag = true; }
    ~Coordinating() { *flag = false; }
  } coordinating(&coordinated_);
  std::vector<std::string> refs;
  for (const auto& e : instances_) refs.push_back(e->ref_);
  /* Reverse load order. */
  std::sort(refs.begin(), refs.end(),
            [this](const std::string& a, const std::string& b) {
              InstPtr x = find(a), y = find(b);
              if (!x || !y) return false;
              if (x->pos_ != y->pos_) return x->pos_ > y->pos_;
              return a > b;
            });
  for (const auto& r : refs) {
    if (find(r)) unload(r);
  }
}

}  // namespace plugin
