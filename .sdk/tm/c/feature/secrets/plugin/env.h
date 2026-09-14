// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/env.h)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Environment overrides (§9.5) — level 7 of the ladder. Pure: a
 * function over a string map and a ref set, so the corpus tests it
 * without touching a real environment. */

#ifndef VOXGIG_PLUGIN_ENV_H
#define VOXGIG_PLUGIN_ENV_H

#include "types.h"
#include "value.h"

/* `retry$fast` -> `RETRY__FAST`. Lossy on purpose; see env.c. */
const char *encoderef(const char *ref);

Value *applyenv(Value *input);

#endif
