// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/host.h)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The host: the lifecycle state machine (§5), extension points (§6),
 * and resource capture (§8).
 *
 * TWO RULES SHAPE EVERY FUNCTION BELOW.
 *
 * Transitions are SEQUENTIAL (§5.2). One at a time, in call order,
 * never interleaved; a transition triggered from inside a lifecycle
 * callback is `plugin_reentrant`. A hard rule, because it is the only
 * way the semantics can be identical in Go, in Ruby and in
 * single-threaded JavaScript — and in C, which has no event loop to
 * hide behind.
 *
 * Reconciliation is EAGER (§18's portability budget). A transition
 * settles by running the state machine to a fixed point, not by
 * suspending on a promise. */

#ifndef VOXGIG_PLUGIN_HOST_H
#define VOXGIG_PLUGIN_HOST_H

#include <stdbool.h>

#include "catalog.h"
#include "point.h"
#include "types.h"
#include "value.h"

typedef struct Host Host;

/* A scope release. C has no closures, so a release is a function plus
 * its context — the same pairing `point.h` uses for bindings. */
typedef void (*ReleaseFn)(void *ctx);

typedef struct HostOptions {
  Catalog *catalog;
  Value *reserved;     /* list of names */
  Value *keys;         /* {instance, default} */
  Value *defaults;     /* {name -> options} */
  Value *profile;
  /* {point -> {kind, mode, exclusive, default, pin}}; the chain base
   * and provider default are functions, so they ride alongside. */
  Value *points;
  HookFn *basefns;     /* parallel to `basepoints` */
  Value *basepoints;   /* list of point names having a base fn */
  /* §11.3. `restart` (the default) treats provider replacement as an
   * ordinary runtime operation. `hold` is the strict reading —
   * deactivating a required instance is `plugin_dependency_held`. NOT
   * the default, because a station that cannot swap a provider without
   * a restart has lost the argument for having a plugin system. */
  const char *dependency;
} HostOptions;

Host *makehost(HostOptions *opts);

Catalog *host_catalog(Host *h);
void host_define(Host *h, Definition *def);

/* --- the state machine --------------------------------------------- */

typedef struct DeclareSpec {
  const char *definition;
  Value *options;
  Value *order;
  bool haspos;
  double pos;
  const char *tag;
  /* §9.1: set ONLY by `hostdeclare` — "the host declares those
   * instances itself, after the user merge, and always wins". */
  bool hostowned;
} DeclareSpec;

Inst *host_declare(Host *h, const char *ref, DeclareSpec *spec);
Inst *host_load(Host *h, const char *ref, DeclareSpec *spec);
Inst *host_activate(Host *h, const char *ref);
Inst *host_deactivate(Host *h, const char *ref);
void host_unload(Host *h, const char *ref);
Inst *host_ready(Host *h, const char *ref);
void host_close(Host *h);
void host_apply(Host *h, Value *doc, Value *profile);
void host_setoptions(Host *h, const char *ref, Value *patch);
const char *host_autotag(Host *h, const char *name);

/* --- observation ---------------------------------------------------- */

/* Introspection NEVER advances the state (§5.2). A status page must not
 * be a way to accidentally import twenty packages. */
Value *host_list(Host *h);
Inst *host_instance(Host *h, const char *ref);
Value *host_observable(Host *h, Value *result, bool hasresult);
Value *host_trace(Host *h);
Value *host_order(Host *h, const char *point);
Value *host_positionof(Host *h, const char *ref, const char *point);

/* --- points --------------------------------------------------------- */

Value *host_emit(Host *h, const char *point, Value *arg);
Value *host_call(Host *h, const char *point, Value *arg);
Value *host_provider(Host *h, const char *point, Value *arg);
Value *host_shadowed(Host *h, const char *point);
Value *host_exports(Host *h, const char *spec);
Value *host_capability(Host *h, const char *name);

/* --- the instance api, as callbacks see it -------------------------- */

const char *inst_ref(Inst *i);
const char *inst_name(Inst *i);
const char *inst_tag(Inst *i);
Value *inst_options(Inst *i);
Value *inst_state(Inst *i);
Host *inst_host(Inst *i);
Inst *inst_of(Host *h, const char *ref);

void inst_bind(Inst *i, const char *point, HookFn hook, ChainFn chain,
               void *ctx, Value *band);
void inst_export(Inst *i, const char *key, Value *value);
void inst_provides(Inst *i, Value *p);
/* Returns a handle a plugin can hand back early. The scope still holds
 * the entry and unwinding it twice is a no-op — releasing early must
 * not make teardown wrong. */
typedef struct ScopeEntry AcquireHandle;
AcquireHandle *inst_acquire(Inst *i);
void inst_giveback(Inst *i, AcquireHandle *handle);
void inst_release(Inst *i, ReleaseFn fn, void *ctx);
Value *inst_position(Inst *i, const char *point);
Host *inst_nest(Inst *i, HostOptions *opts);

/* The driver reads these to build §4.5's observable. */
Value *inst_status(Inst *i);
double inst_seq(Inst *i);
double inst_pos(Inst *i);
Host *inst_inner(Inst *i);

#endif
