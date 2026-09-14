// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/order.h)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Ordering (§7) — constraints, then bands, then declaration position.
 * CONSTRAINTS BEAT BANDS so the correct tool wins when both are
 * present; a band chosen by trial and error to fix an ordering bug is a
 * bug wearing a number. See order.c. */

#ifndef VOXGIG_PLUGIN_ORDER_H
#define VOXGIG_PLUGIN_ORDER_H

#include "types.h"
#include "value.h"

/* [{ref, pos, order?}] plus an optional host pin -> [ref] */
Value *resolveorder(Value *bindings, Value *pin);

#endif
