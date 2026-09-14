// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/ref.h)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Identity: name+tag, written `name$tag` (§4).
 *
 * The four pure functions, and the whole of what `ref` pins. They are
 * the first thing a new port implements and the first corpus section it
 * passes. */

#ifndef VOXGIG_PLUGIN_REF_H
#define VOXGIG_PLUGIN_REF_H

#include <stdbool.h>

#include "types.h"
#include "value.h"

/* §4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024. */
bool checkname(Value *name);
/* §4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
 *
 * The asymmetry with a name is deliberate: a tag MAY start with a digit
 * because auto-tagging assigns integer tags (`stripe$1`), and a tag
 * admits neither `@` nor `/` because a name is a package specifier and
 * a tag is not. */
bool checktag(Value *tag);

/* `name$tag` -> {name, tag}. Canonicalizing: `stripe$` and `stripe`
 * both give tag ''. Raises plugin_bad_name / plugin_bad_tag. */
Value *parseref(Value *str);
/* {name, tag} -> `name$tag`. An empty tag NEVER writes the separator,
 * which is the half of canonicalization formatref owns: parse tolerates
 * `stripe$`, format never produces it, so a round trip is idempotent. */
const char *formatref(Value *name, Value *tag);
/* The canonical spelling. §4 rule 5: canonicalize before comparison. */
const char *canonref(Value *str);

/* The canonical ref this string denotes, or NULL if it denotes none —
 * the TOLERANT half of `canonref`, and the one a requirement name needs
 * (§11.1). Capability names are free-form, so `2fa` is a good one and
 * no ref could be called that; `canonref` RAISES on those, and asking it
 * "is this a ref?" made a legal document kill the host. */
const char *tryref(const char *str);

/* `canonref` for internal callers that want the input back unchanged
 * when it is not well formed. NEVER use where a bad ref must be
 * reported — the corpus pins plugin_bad_name at every public entry. */
const char *canon(const char *str);
/* The name half, for internal callers that only compare. */
const char *refname(const char *str);

#endif
