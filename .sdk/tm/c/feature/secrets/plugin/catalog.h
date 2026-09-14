// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/catalog.h)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The definition catalog (§10.1).
 *
 * A definition is registered once and may back many instances. Option
 * shapes are validated AT REGISTRATION, not when a document happens to
 * exercise a key — so a malformed shape fails once, and in the same
 * place everywhere (§9.4). `declare/shape` pins that timing. */

#ifndef VOXGIG_PLUGIN_CATALOG_H
#define VOXGIG_PLUGIN_CATALOG_H

#include <stdbool.h>

#include "types.h"
#include "value.h"

typedef struct Inst Inst;

/* A DEFINITION IS DATA WITH FUNCTIONS IN IT, not a class to extend. A
 * document could produce one, which is the property that makes a
 * catalog a data structure rather than a compile-time registry. */
typedef void (*LifecycleFn)(Inst *inst);
typedef void (*ReconfigureFn)(Inst *inst, Value *now, Value *previous);

typedef struct Definition {
  const char *name;
  Value *shape;
  LifecycleFn define;
  LifecycleFn activate;
  LifecycleFn deactivate;
  LifecycleFn close;
  ReconfigureFn reconfigure;
} Definition;

typedef struct Catalog Catalog;

Catalog *makecatalog(void);
void catalog_add(Catalog *c, Definition *def);
Definition *catalog_get(Catalog *c, const char *name);
bool catalog_has(Catalog *c, const char *name);
Value *catalog_names(Catalog *c);

/* The callback for a phase, by the name the log and the corpus use. */
LifecycleFn definition_callback(Definition *d, const char *at);

#endif
