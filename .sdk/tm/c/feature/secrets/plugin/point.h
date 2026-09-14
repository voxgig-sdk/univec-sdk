// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/point.h)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Extension points (§6). Three kinds, chosen because they are what the
 * two existing systems actually needed, and no more.
 *
 * A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
 * deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
 * undoable, but "this instance holds slot 3 of the request chain" is
 * undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
 * paper called *Listeners Considered Harmful*, and for exactly this
 * reason.
 *
 * A CLOSURE IN C IS A FUNCTION POINTER PLUS A CONTEXT, and that is the
 * whole of what this header adds over the canonical. `chain` needs to
 * hand a binding its `next`, which in every other port is a closure the
 * composition builds; here `next` is an explicit `Chain *` the binding
 * calls back into. Same composition, same order, no hidden state. */

#ifndef VOXGIG_PLUGIN_POINT_H
#define VOXGIG_PLUGIN_POINT_H

#include <stdbool.h>

#include "types.h"
#include "value.h"

/* The remaining composition, as seen by one chain binding. Opaque: a
 * binding may CALL it and must not store it — a plugin that stashes
 * `next` and calls it after deactivation is a bug the host cannot
 * prevent, and saying so is better than pretending otherwise (§6.2). */
typedef struct Chain Chain;

/* A hook or provider binding. */
typedef Value *(*HookFn)(Value *arg, void *ctx);
/* A chain binding: it receives its `next` and the argument. */
typedef Value *(*ChainFn)(Chain *next, Value *arg, void *ctx);

typedef struct Bound {
  const char *ref;
  const char *point;
  /* `provider` ranks by HIGHEST band, unlike hook and chain which run
   * lowest first. Kept as declared so the two rules stay visibly
   * different rather than one being derived from the other by a reader
   * who then gets it backwards. */
  double band;
  HookFn hook;
  ChainFn chain;
  void *ctx;
} Bound;

/* Call the rest of the composition. */
Value *chain_next(Chain *c, Value *arg);

/* Fan-out. Return values are ignored except in `bail`.
 *
 * §6.1: "fan-out" is not one answer but four. In a language with
 * asynchrony, "call every binding" hides a decision — start them all
 * and wait, await each in turn, or do not wait — and a design that
 * leaves it unsaid gets four different answers from four ports, in the
 * concurrency behaviour of production code no corpus entry happens to
 * cover. C has no asynchrony, so all four modes are sequential here and
 * only the ERROR and RETURN handling distinguishes them.
 *
 * `errors` receives the collected raises for the gathering modes. */
Value *point_emit(Bound **bindings, size_t n, const char *mode, Value *arg,
                  Value **errors);

/* Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2). */
Value *point_call(Bound **bindings, size_t n, HookFn base, void *basectx,
                  Value *arg);

/* At most one live implementation (§6.3). The winner is the highest
 * band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
 * silently ignored. Returns the winner (or NULL) and fills `shadowed`
 * with the losing refs, in sorted order. */
Bound *point_provider(Bound **bindings, size_t n, bool exclusive,
                      Value **shadowed);

#endif
