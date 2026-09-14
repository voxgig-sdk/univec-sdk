// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/host.hpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The host: the lifecycle state machine (§5), extension points (§6),
 * and resource capture (§8).
 *
 * TWO RULES SHAPE EVERY METHOD BELOW.
 *
 * Transitions are SEQUENTIAL (§5.2). One at a time, in call order,
 * never interleaved; a transition triggered from inside a lifecycle
 * callback is `plugin_reentrant`. A hard rule, because it is the only
 * way the semantics can be identical in Go, in Ruby and in
 * single-threaded JavaScript — and in C++, which has no event loop to
 * hide behind.
 *
 * Reconciliation is EAGER (§18's portability budget). A transition
 * settles by running the state machine to a fixed point, not by
 * suspending on a future. */

#ifndef VOXGIG_PLUGIN_HOST_HPP
#define VOXGIG_PLUGIN_HOST_HPP

#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "catalog.hpp"
#include "point.hpp"
#include "types.hpp"
#include "value.hpp"

namespace plugin {

class Host;
using HostPtr = std::shared_ptr<Host>;

/* A scope release: a closure, so an instance's teardown captures
 * whatever it needs rather than being handed a void* the way c must. */
using Release = std::function<void()>;

struct HostOptions {
  CatalogPtr catalog;
  V reserved;        /* list of names */
  V keys;            /* {instance, default} */
  V defaults;        /* {name -> options} */
  V profile;
  /* {point -> {kind, mode, exclusive, default, pin}}; the chain base is
   * a function, so it rides alongside rather than inside the map. */
  V points;
  std::map<std::string, Hook> bases;
  /* §11.3. `restart` (the default) treats provider replacement as an
   * ordinary runtime operation. `hold` is the strict reading —
   * deactivating a required instance is `plugin_dependency_held`. NOT
   * the default, because a station that cannot swap a provider without
   * a restart has lost the argument for having a plugin system. */
  std::string dependency;
};

struct DeclareSpec {
  std::string definition;
  V options;
  V order;
  bool haspos = false;
  double pos = 0;
  std::string tag;
  /* §9.1: set ONLY by `hostdeclare` — "the host declares those
   * instances itself, after the user merge, and always wins". */
  bool hostowned = false;
};

/* A scope entry. `acquire` hands back a shared_ptr to one so a plugin
 * can release early; the scope keeps the entry, and unwinding it twice
 * is a no-op. */
struct ScopeEntry {
  Release fn;
  bool done = false;
  /* `acquire` and `release` both count toward `open`; a nested host's
   * teardown does NOT — a teardown is not an acquisition, and the inner
   * host keeps its own counter (`nest/open`). */
  bool counts = true;
};
using AcquireHandle = std::shared_ptr<ScopeEntry>;

class Inst {
 public:
  /* --- identity and configuration, as callbacks see it -------------- */
  const std::string& ref() const { return ref_; }
  std::string name() const;
  std::string tag() const;
  const V& options() const { return options_; }
  const V& state() const { return state_; }
  Host& host() const { return *owner_; }

  /* --- what a definition declares ----------------------------------- */
  void bind(const std::string& point, Hook hook, ChainFn chain, const V& band);
  void bindhook(const std::string& point, Hook hook, const V& band);
  void bindchain(const std::string& point, ChainFn chain, const V& band);
  void exportvalue(const std::string& key, const V& value);
  void provides(const V& p);
  /* Returns a handle a plugin can hand back early. The scope still
   * holds the entry and unwinding it twice is a no-op — releasing early
   * must not make teardown wrong. */
  AcquireHandle acquire();
  void giveback(const AcquireHandle& handle);
  void release(Release fn);
  V position(const std::string& point) const;
  HostPtr nest(const HostOptions& opts);

  /* --- observation --------------------------------------------------- */
  const std::string& status() const { return status_; }
  double seq() const { return seq_; }
  double pos() const { return pos_; }
  HostPtr inner() const { return inner_; }

 private:
  friend class Host;

  std::string ref_;
  DefinitionPtr def_;
  std::string status_ = "declared";
  double pos_ = 0;
  double seq_ = 0;
  V options_ = vmap();
  V state_ = vmap();
  V order_;
  /* §11.4's ALWAYS-RELUCTANT rebinding, made concrete: the provider ref
   * this instance's activation actually selected, per requirement name.
   * Recomputing the best candidate on every question silently re-points
   * a live consumer at any better-ranked newcomer, and then losing the
   * provider it was really using does not restart it. */
  V selected_ = vmap();
  /* §9.6's `active: false`. THE BAR OUTLIVES THE APPLY THAT SET IT: a
   * flag consulted only while `apply` ran let a later direct `ready`
   * bring the instance live, which is the config switch it exists to be
   * silently ignored. */
  bool barred_ = false;
  V unmet_ = vlist();
  std::vector<AcquireHandle> scope_;
  /* Declared in `define`, inserted only when activation SUCCEEDS
   * (§8.1). Holding them until then is what makes a failed activate
   * leave nothing behind. */
  std::vector<Bound> bindings_;
  HostPtr inner_;
  /* Declared in `define`, and VISIBLE while merely `loaded` (§11): they
   * are data, and hiding them would make the loaded state useless for
   * introspection. */
  V exports_ = vmap();
  V provides_ = vlist();
  Host* owner_ = nullptr;
};

using InstPtr = std::shared_ptr<Inst>;

class Host {
 public:
  explicit Host(const HostOptions& opts);

  Catalog& catalog() { return *catalog_; }
  CatalogPtr catalogptr() { return catalog_; }
  void define(const DefinitionPtr& def) { catalog_->add(def); }

  /* --- the state machine -------------------------------------------- */
  InstPtr declare(const std::string& ref, const DeclareSpec& spec);
  InstPtr load(const std::string& ref, const DeclareSpec& spec);
  InstPtr activate(const std::string& ref);
  InstPtr deactivate(const std::string& ref);
  void unload(const std::string& ref);
  InstPtr ready(const std::string& ref);
  void close();
  void apply(const V& doc, const V& profile);
  void setoptions(const std::string& ref, const V& patch);
  std::string autotag(const std::string& name) const;

  /* --- observation --------------------------------------------------- */
  /* Introspection NEVER advances the state (§5.2). A status page must
   * not be a way to accidentally import twenty packages. */
  V list() const;
  InstPtr instance(const std::string& ref) const;
  V observable(const V& result, bool hasresult) const;
  /* A COPY, not the live list: the canonical is `trace: () => events.slice()`, and `observable` already copies the log. Returning the live list lets a caller append to or delete from the host's own event record — application observation code fabricating or erasing lifecycle history. */
  V trace() const;
  V order(const std::string& point) const;
  V positionof(const std::string& ref, const std::string& point) const;

  /* --- points --------------------------------------------------------- */
  V emit(const std::string& point, const V& arg);
  V call(const std::string& point, const V& arg);
  V provider(const std::string& point, const V& arg);
  V shadowed(const std::string& point) const;
  V exports(const std::string& spec) const;
  V capability(const std::string& name) const;

 private:
  friend class Inst;

  InstPtr find(const std::string& ref) const;
  std::vector<std::string> sortedrefs() const;
  void guard() const;
  InstPtr need(const std::string& ref) const;
  void checkreserved(const std::string& ref) const;
  void run(const InstPtr& e, const std::string& at);
  V unwind(const InstPtr& e);
  void releasecheck(const InstPtr& e, const V& errors);
  V providersof(const V& req) const;
  V unmetof(const InstPtr& e) const;
  std::string chosen(const InstPtr& e, const V& req, bool remember) const;
  V boundproviders(const InstPtr& e) const;
  V consumersof(const std::string& ref) const;
  V holdersof(const std::string& ref) const;
  void held(const InstPtr& e) const;
  V graphnodes() const;
  std::vector<Bound> boundon(const std::string& point) const;
  V pointspec(const std::string& point) const;
  void cascade(const InstPtr& provider, const V& seen);
  void reconcile();
  V shapeof(const std::string& ref) const;

  CatalogPtr catalog_;
  V reserved_;
  V keys_;
  V defaults_;
  V profile_;
  V points_;
  std::map<std::string, Hook> bases_;
  std::string dependency_ = "restart";
  /* Set for the duration of a bulk teardown, so `held` knows this is a
   * coordinated operation rather than an ad-hoc deactivation. */
  bool coordinated_ = false;

  std::vector<InstPtr> instances_;
  V log_ = vlist();
  V events_ = vlist();
  double seqn_ = 0;
  double open_ = 0;
  bool intransition_ = false;
  /* WHICH callback is running, not merely that one is. §8.1 puts
   * resource capture in `activate` and §8.3 says `release` outside
   * `activate` is `plugin_release_scope` — and a boolean alone cannot
   * tell `activate` from `define`, so it admitted an acquire in
   * `define` whose scope `unload` would never unwind. */
  std::string phase_;
};

HostPtr makehost(const HostOptions& opts);

}  // namespace plugin

#endif
