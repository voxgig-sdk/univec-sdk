// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/resolve.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Dynamic resolution (§10.2) — name to candidate module ids.
 *
 * PURE. It returns the ids a host WOULD try, in order; it does not load
 * anything. That separation is what lets the corpus pin resolution in
 * every language including those with no dynamic loading at all — c
 * among them — and it is why §15.4 puts real module loading in per-port
 * integration tests rather than here. */

#include <stdio.h>
#include <string.h>

#include "resolve.h"

static void pushuniq(Value *out, const char *id) {
  for (size_t i = 0; i < vlen(out); i++) {
    if (0 == strcmp(vasstr(vat(out, i)), id)) return;
  }
  vpush(out, vstr(id));
}

Value *resolvecandidates(Value *name, Value *sources) {
  Value *out = vlist();
  const char *n = visstr(name) ? vasstr(name) : "";

  /* A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
   * already a package id; prefixing it produces
   * `@voxgig/plugin-@acme/thing`, which is not a thing that can exist. */
  if ('@' == n[0]) {
    vpush(out, vstr(n));
    return out;
  }

  static const char *DEFAULT_PREFIX[] = {
    "@voxgig/plugin-", "voxgig-plugin-", "plugin-", "", NULL
  };

  bool given = vislist(sources) && 0 < vlen(sources);
  if (!given) {
    for (int i = 0; NULL != DEFAULT_PREFIX[i]; i++) {
      size_t sz = strlen(DEFAULT_PREFIX[i]) + strlen(n) + 1;
      char *id = (char *)arena_alloc(sz);
      snprintf(id, sz, "%s%s", DEFAULT_PREFIX[i], n);
      pushuniq(out, id);
    }
    return out;
  }

  for (size_t si = 0; si < vlen(sources); si++) {
    Value *src = vat(sources, si);
    const char *kind = visstr(vget(src, "kind")) ? vasstr(vget(src, "kind")) : "";

    if (0 == strcmp(kind, "module")) {
      Value *prefix = vget(src, "prefix");
      if (vislist(prefix) && 0 < vlen(prefix)) {
        for (size_t pi = 0; pi < vlen(prefix); pi++) {
          const char *p = visstr(vat(prefix, pi)) ? vasstr(vat(prefix, pi)) : "";
          size_t sz = strlen(p) + strlen(n) + 1;
          char *id = (char *)arena_alloc(sz);
          snprintf(id, sz, "%s%s", p, n);
          pushuniq(out, id);
        }
      }
      else {
        pushuniq(out, n);
      }
    }
    else if (0 == strcmp(kind, "path")) {
      const char *dir = visstr(vget(src, "dir")) ? vasstr(vget(src, "dir")) : "";
      /* Trailing slashes are trimmed, so `lib/` and `lib` give one id
       * rather than two spellings of it. */
      size_t dl = strlen(dir);
      while (0 < dl && '/' == dir[dl - 1]) dl--;
      size_t sz = dl + strlen(n) + 2;
      char *id = (char *)arena_alloc(sz);
      snprintf(id, sz, "%.*s/%s", (int)dl, dir, n);
      pushuniq(out, id);
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
Value *resolvefrom(Value *from) {
  Value *out = vlist();
  vpush(out, visnull(from) ? vnull() : from);
  return out;
}
