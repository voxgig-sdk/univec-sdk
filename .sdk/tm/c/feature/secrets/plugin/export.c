// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/export.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Exports (§11).
 *
 * THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client`
 * resolves to the UNTAGGED instance if one exists; if not, and exactly
 * one tagged instance exports that key, it resolves to that one; if two
 * do, it is `plugin_export_ambiguous` — deliberately diverging from
 * seneca's silent last-wins, because with multi-instance as a headline
 * feature an ambiguous alias is a defect waiting for production. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "export.h"
#include "ref.h"

static int bytewise(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

Value *resolveexport(Value *spec, Value *exported) {
  const char *s = visstr(spec) ? vasstr(spec) : "";
  const char *cut = strchr(s, '/');
  if (NULL == cut) {
    size_t sz = strlen(s) + 40;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "export spec needs a key: %s", s);
    fail("plugin_export_ambiguous", text, details1("spec", vstr(s)));
  }
  const char *head = arena_strndup(s, (size_t)(cut - s));
  const char *key = cut + 1;

  /* A fully qualified ref: exactly one answer or none.
   *
   * VALIDATING, not tolerant. The canonical calls `canonref(head)`,
   * which RAISES — so `retry$bad!/client` is `plugin_bad_tag` and
   * `2fa/client` is `plugin_bad_name`. Reading it with `tryref` turned
   * a configuration typo into an ordinary missing export, which is the
   * error the caller most needs to see, silently swallowed. */
  const char *want = canonref(vstr(head));
  {
    for (size_t i = 0; i < vlen(exported); i++) {
      Value *e = vat(exported, i);
      if (0 == strcmp(vasstr(vget(e, "ref")), want) &&
          0 == strcmp(vasstr(vget(e, "key")), key)) {
        return vget(e, "value");
      }
    }
  }

  /* An alias: the NAME, not a ref. Look at every instance of it. */
  Value *byname = vlist();
  for (size_t i = 0; i < vlen(exported); i++) {
    Value *e = vat(exported, i);
    const char *eref = vasstr(vget(e, "ref"));
    if (0 == strcmp(refname(eref), head) &&
        0 == strcmp(vasstr(vget(e, "key")), key)) {
      vpush(byname, e);
    }
  }
  if (0 == vlen(byname)) return NULL;

  /* The untagged instance wins outright when there is one. */
  for (size_t i = 0; i < vlen(byname); i++) {
    Value *e = vat(byname, i);
    const char *eref = vasstr(vget(e, "ref"));
    if (NULL == strchr(eref, '$')) return vget(e, "value");
  }

  if (1 == vlen(byname)) return vget(vat(byname, 0), "value");

  size_t n = vlen(byname);
  const char **refs = (const char **)arena_alloc(sizeof(char *) * (n + 1));
  size_t sz = strlen(s) + 64;
  for (size_t i = 0; i < n; i++) {
    refs[i] = vasstr(vget(vat(byname, i), "ref"));
    sz += strlen(refs[i]) + 4;
  }
  if (1 < n) qsort((void *)refs, n, sizeof(char *), bytewise);
  Value *list = vlist();
  for (size_t i = 0; i < n; i++) vpush(list, vstr(refs[i]));

  char *text = (char *)arena_alloc(sz);
  size_t used = (size_t)snprintf(text, sz, "alias %s matches %zu instances: ", s, n);
  for (size_t i = 0; i < n; i++) {
    used += (size_t)snprintf(text + used, sz - used, "%s%s",
                             0 < i ? ", " : "", refs[i]);
  }
  Value *d = vmap();
  vset(d, "spec", vstr(s));
  vset(d, "refs", list);
  fail("plugin_export_ambiguous", text, d);
  return NULL;
}
