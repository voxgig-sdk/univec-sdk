// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/version.h)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Versions and ranges (§11.2).
 *
 * TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
 * concrete version. A requirement declares `range`. A requirement is
 * satisfied when the names match, the `match` passes, and the
 * provider's `version` falls inside the requirement's `range`. That is
 * the whole rule — there is no third field and no second comparison. */

#ifndef VOXGIG_PLUGIN_VERSION_H
#define VOXGIG_PLUGIN_VERSION_H

#include <stdbool.h>

#include "types.h"
#include "value.h"

/* A parsed range is {lo:[3], hi:[3]} — the shape `version/range` asserts
 * directly, so it is a Value rather than a struct. */
Value *parserange(Value *range);
/* [major, minor, patch]. */
Value *parseversion(Value *version);

/* The one satisfaction predicate: lo <= version < hi. */
bool satisfies(Value *version, Value *range);
/* The same, tolerant of a missing version — a bare ref carries none, so
 * `graph` and `depend` ask this rather than raising. */
bool satisfiesq(Value *version, Value *range);

int vercmp(Value *a, Value *b);

#endif
