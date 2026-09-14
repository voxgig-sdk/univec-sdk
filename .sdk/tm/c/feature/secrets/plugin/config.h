// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/config.h)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The declarative document (§9): normalization, and the ten-level
 * precedence ladder. See config.c for why the two functions are split. */

#ifndef VOXGIG_PLUGIN_CONFIG_H
#define VOXGIG_PLUGIN_CONFIG_H

#include "types.h"
#include "value.h"

/* {instance: {ref -> entry}, order: [ref], default: {name -> entry}} */
Value *normalizeconfig(Value *input);

/* §9.3's ten levels, and §9.4's merge directives. */
Value *resolveoptions(Value *input);

/* §9.4: validated WHEN THE SHAPE ENTERS THE CATALOG, not when a
 * document exercises the key — so a malformed shape fails once, and in
 * the same place everywhere. `declare/shape` pins the timing. */
void checkshape(Value *shape);

#endif
