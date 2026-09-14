// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/point.hpp)
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
 * A CLOSURE IS A CLOSURE, which is the whole difference from the `c`
 * port. `std::function` captures, so a chain binding receives its
 * `next` as a callable the composition built — the same shape the
 * canonical writes — instead of c's explicit `Chain *` walked by index.
 * Nothing else about the composition changes. */

#ifndef VOXGIG_PLUGIN_POINT_HPP
#define VOXGIG_PLUGIN_POINT_HPP

#include <functional>
#include <string>
#include <vector>

#include "types.hpp"
#include "value.hpp"

namespace plugin {

/* A hook or provider binding. */
using Hook = std::function<V(const V& arg)>;
/* The remaining composition, as seen by one chain binding. A binding
 * may CALL it and must not store it — a plugin that stashes `next` and
 * calls it after deactivation is a bug the host cannot prevent, and
 * saying so is better than pretending otherwise (§6.2). */
using Next = std::function<V(const V& arg)>;
using ChainFn = std::function<V(const Next& next, const V& arg)>;

struct Bound {
  std::string ref;
  std::string point;
  /* `provider` ranks by HIGHEST band, unlike hook and chain which run
   * lowest first. Kept as declared so the two rules stay visibly
   * different rather than one being derived from the other by a reader
   * who then gets it backwards. */
  double band = 0;
  Hook hook;
  ChainFn chain;
};

/* Fan-out. Return values are ignored except in `bail`.
 *
 * §6.1: "fan-out" is not one answer but four. In a language with
 * asynchrony, "call every binding" hides a decision — start them all
 * and wait, await each in turn, or do not wait — and a design that
 * leaves it unsaid gets four different answers from four ports, in the
 * concurrency behaviour of production code no corpus entry happens to
 * cover. This port is synchronous, so all four modes are sequential
 * here and only the ERROR and RETURN handling distinguishes them.
 *
 * `errors` receives the collected raises for the gathering modes. */
V pointemit(const std::vector<Bound>& bindings, const std::string& mode,
            const V& arg, V& errors);

/* Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2). */
V pointcall(const std::vector<Bound>& bindings, const Hook& base, const V& arg);

/* At most one live implementation (§6.3). The winner is the highest
 * band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
 * silently ignored. Returns the winner's index (or -1) and fills
 * `shadowed` with the losing refs, in ranked order. */
long pointprovider(const std::vector<Bound>& bindings, bool exclusive,
                   V& shadowed);

}  // namespace plugin

#endif
