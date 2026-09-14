// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/catalog.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The definition catalog (§10.1). */

#include <stdio.h>
#include <string.h>

#include "catalog.h"
#include "config.h"
#include "ref.h"

typedef struct CatEntry {
  const char *name;
  Definition *def;
  struct CatEntry *next;
} CatEntry;

struct Catalog {
  CatEntry *first;
};

Catalog *makecatalog(void) {
  Catalog *c = (Catalog *)arena_alloc(sizeof(Catalog));
  c->first = NULL;
  return c;
}

void catalog_add(Catalog *c, Definition *def) {
  if (NULL == def || !checkname(vstr(NULL == def->name ? "" : def->name))) {
    const char *shown = (NULL == def || NULL == def->name) ? "" : def->name;
    size_t sz = strlen(shown) + 48;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "invalid definition name: %s", shown);
    fail("plugin_definition_name", text, NULL);
  }

  /* Validate the shape HERE. Deferring it to resolution time means a
   * malformed shape surfaces at a different moment in every host that
   * loads it, which is the divergence the stated domain exists to
   * prevent. */
  if (!visnull(def->shape)) checkshape(def->shape);

  for (CatEntry *e = c->first; NULL != e; e = e->next) {
    if (0 == strcmp(e->name, def->name)) { e->def = def; return; }
  }
  CatEntry *e = (CatEntry *)arena_alloc(sizeof(CatEntry));
  e->name = arena_strdup(def->name);
  e->def = def;
  e->next = c->first;
  c->first = e;
}

Definition *catalog_get(Catalog *c, const char *name) {
  if (NULL == c || NULL == name) return NULL;
  for (CatEntry *e = c->first; NULL != e; e = e->next) {
    if (0 == strcmp(e->name, name)) return e->def;
  }
  return NULL;
}

bool catalog_has(Catalog *c, const char *name) {
  return NULL != catalog_get(c, name);
}

Value *catalog_names(Catalog *c) {
  Value *m = vmap();
  for (CatEntry *e = c->first; NULL != e; e = e->next) vset(m, e->name, vbool(true));
  const char **keys;
  size_t n = vsortedkeys(m, &keys);
  Value *out = vlist();
  for (size_t i = 0; i < n; i++) vpush(out, vstr(keys[i]));
  return out;
}

LifecycleFn definition_callback(Definition *d, const char *at) {
  if (NULL == d) return NULL;
  if (0 == strcmp(at, "define")) return d->define;
  if (0 == strcmp(at, "activate")) return d->activate;
  if (0 == strcmp(at, "deactivate")) return d->deactivate;
  if (0 == strcmp(at, "close")) return d->close;
  return NULL;
}
