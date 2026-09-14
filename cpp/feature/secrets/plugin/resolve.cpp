// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/resolve.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Dynamic resolution (§10.2). See resolve.hpp. */

#include "resolve.hpp"

namespace plugin {

static void pushuniq(const V& out, const std::string& id) {
  for (size_t i = 0; i < len(out); i++) {
    if (asstr(at(out, i)) == id) return;
  }
  push(out, vstr(id));
}

V resolvecandidates(const V& name, const V& sources) {
  V out = vlist();
  const std::string n = isstr(name) ? asstr(name) : "";

  /* A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
   * already a package id; prefixing it produces
   * `@voxgig/plugin-@acme/thing`, which is not a thing that can exist. */
  if (!n.empty() && '@' == n[0]) {
    push(out, vstr(n));
    return out;
  }

  static const char* const DEFAULT_PREFIX[] = {
    "@voxgig/plugin-", "voxgig-plugin-", "plugin-", "", nullptr
  };

  bool given = islist(sources) && 0 < len(sources);
  if (!given) {
    for (int i = 0; nullptr != DEFAULT_PREFIX[i]; i++) {
      pushuniq(out, std::string(DEFAULT_PREFIX[i]) + n);
    }
    return out;
  }

  for (size_t si = 0; si < len(sources); si++) {
    V src = at(sources, si);
    const std::string kind = asstr(get(src, "kind"));

    if ("module" == kind) {
      V prefix = get(src, "prefix");
      if (islist(prefix) && 0 < len(prefix)) {
        for (size_t pi = 0; pi < len(prefix); pi++) {
          pushuniq(out, asstr(at(prefix, pi)) + n);
        }
      }
      else {
        pushuniq(out, n);
      }
    }
    else if ("path" == kind) {
      std::string dir = asstr(get(src, "dir"));
      /* Trailing slashes are trimmed, so `lib/` and `lib` give one id
       * rather than two spellings of it. */
      while (!dir.empty() && '/' == dir.back()) dir.pop_back();
      pushuniq(out, dir + "/" + n);
    }
  }

  return out;
}

/* A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a name
 * with a letter or `@`, so `./local/thing` is not a ref and never
 * reaches candidate generation — seneca allows a path where a plugin
 * name goes, and this design deliberately does not, because a ref is an
 * ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.
 *
 * Loading from an explicit location bypasses candidate generation
 * entirely: `from` is passed to the resolver verbatim. */
V resolvefrom(const V& from) {
  V out = vlist();
  push(out, isnull(from) ? vnull() : from);
  return out;
}

}  // namespace plugin
