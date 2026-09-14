// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/depend.h)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Dependency cardinality, policy, and the restart graph (§11.3). Two
 * axes, both declared by the definition that has the requirement,
 * because only it knows what it can cope with. See depend.c. */

#ifndef VOXGIG_PLUGIN_DEPEND_H
#define VOXGIG_PLUGIN_DEPEND_H

#include <stdbool.h>

#include "types.h"
#include "value.h"

Value *normrequire(Value *r);
Value *requirements(Value *options);

bool restartsonloss(Value *r);
bool gatesactivation(Value *r);
bool restartcausing(Value *r);

/* [{ref, provides:[name], requires:[req]}] -> the cycle, or NULL. */
Value *dependencycycle(Value *nodes);
/* Raise on a cycle, naming it. Separate from the detector so the
 * detector stays pure and corpus-testable. */
void checkcycle(Value *nodes);

#endif
