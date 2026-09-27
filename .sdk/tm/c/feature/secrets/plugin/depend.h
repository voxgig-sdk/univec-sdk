// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (c/src/depend.h)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
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
