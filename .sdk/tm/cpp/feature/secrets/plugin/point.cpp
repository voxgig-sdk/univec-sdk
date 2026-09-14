// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/point.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Extension points (§6). See point.hpp for the closure representation. */

#include "point.hpp"

#include <algorithm>

namespace plugin {

/* The composition, built as nested closures rather than walked by
 * index: `next` is a real callable, so a binding writes `next(arg)` the
 * way the canonical does. Identical to `b1(b2(b3(base)))`. */
static V callat(const std::vector<Bound>& bs, size_t i, const Hook& base,
                const V& arg) {
  if (i >= bs.size()) return base ? base(arg) : arg;
  Next next = [&bs, i, &base](const V& a) { return callat(bs, i + 1, base, a); };
  return bs[i].chain(next, arg);
}

V pointcall(const std::vector<Bound>& bindings, const Hook& base, const V& arg) {
  return callat(bindings, 0, base, arg);
}

V pointemit(const std::vector<Bound>& bindings, const std::string& mode,
            const V& arg, V& errors) {
  errors = vlist();

  if ("bail" == mode) {
    /* Stops at the first binding that RETURNS A VALUE — the "handled,
     * stop" case. A NULLPTR OR A NULL DECLINES.
     *
     * JavaScript can tell null from undefined and almost nothing else
     * in the target set can — Go, Python, Ruby, PHP, Lua, Java and C#
     * each have exactly one way to say nothing, and C++ has one too.
     * Making the distinction load-bearing would cost every one of them
     * a wrapper type carried through the whole dispatch path, to
     * express a difference their plugin authors cannot write. §18's
     * budget settles it (§6.1). */
    for (const auto& b : bindings) {
      V v = b.hook(arg);
      if (!isnull(v)) return v;
    }
    return nullptr;
  }

  bool raising = "emit" == mode;
  for (const auto& b : bindings) {
    if (raising) {
      /* `emit` raises synchronously; the collecting modes gather. */
      b.hook(arg);
      continue;
    }
    try {
      b.hook(arg);
    }
    catch (const PluginError& e) {
      V rec = vmap();
      set(rec, "code", vstr(e.code));
      set(rec, "message", vstr(e.message));
      push(errors, rec);
    }
  }
  return nullptr;
}

long pointprovider(const std::vector<Bound>& bindings, bool exclusive,
                   V& shadowed) {
  shadowed = vlist();
  if (bindings.empty()) return -1;

  std::vector<size_t> ranked(bindings.size());
  for (size_t i = 0; i < bindings.size(); i++) ranked[i] = i;

  if (exclusive && 1 < bindings.size()) {
    std::vector<std::string> refs;
    for (const auto& b : bindings) refs.push_back(b.ref);
    /* Sorted, so the message names the same pair whatever order the
     * bindings arrived in. */
    std::sort(refs.begin(), refs.end());
    V list = vlist();
    std::string names;
    for (size_t i = 0; i < refs.size(); i++) {
      if (0 < i) names += ", ";
      names += refs[i];
      push(list, vstr(refs[i]));
    }
    fail("plugin_point_exclusive",
         "point is exclusive and has " + std::to_string(bindings.size()) +
             " bindings: " + names,
         details1("refs", list));
  }

  /* HIGHEST band wins, unlike hook and chain; ties break by ref sort,
   * which is a TOTAL order, so the unstable sort cannot show. */
  std::sort(ranked.begin(), ranked.end(), [&bindings](size_t a, size_t b) {
    if (bindings[a].band != bindings[b].band) {
      return bindings[a].band > bindings[b].band;
    }
    return bindings[a].ref < bindings[b].ref;
  });

  for (size_t i = 1; i < ranked.size(); i++) {
    push(shadowed, vstr(bindings[ranked[i]].ref));
  }
  return static_cast<long>(ranked[0]);
}

}  // namespace plugin
