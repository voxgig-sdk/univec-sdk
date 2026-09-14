// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/value.h)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The dynamic value, and the JSON reader that fills it (§16).
 *
 * NO DEPENDENCIES, not even a JSON library: §16 permits exactly one
 * runtime dependency (voxgig/struct) and C has no port of it, so the
 * corpus JSON is parsed here. A package graph is also a supply chain.
 *
 * ARENA ALLOCATION, and it is the design rather than a shortcut. Every
 * Value this port makes lives in one arena and the whole arena is freed
 * at once. The alternative — ownership per value, or refcounting — buys
 * nothing a test-driven library needs and costs the thing C ports fail
 * at: a `free` on a path the corpus does not exercise. Nothing here
 * frees an individual value, so nothing here can double-free one.
 *
 * A MAP PRESERVES INSERTION ORDER AND SORTS ON DEMAND. §4 rule 4 makes
 * order observable in several places (`keys` is sorted, `pos` is the
 * sorted-ref index), so both orders have to be available and the code
 * has to say which it means at each use.
 */

#ifndef VOXGIG_PLUGIN_VALUE_H
#define VOXGIG_PLUGIN_VALUE_H

#include <stddef.h>
#include <stdbool.h>

typedef enum {
  VNULL = 0,
  VBOOL,
  VNUM,
  VSTR,
  VLIST,
  VMAP
} VKind;

typedef struct Value Value;

/* A map entry. Kept as a linked list rather than a hash table: the maps
 * here hold a handful of keys, insertion order must survive, and a
 * hashtable would add a growth path with nothing to gain. */
typedef struct VEntry {
  const char *key;
  Value *val;
  struct VEntry *next;
} VEntry;

struct Value {
  VKind kind;
  bool boolean;
  double num;
  const char *str;
  /* list */
  Value **items;
  size_t len;
  size_t cap;
  /* map */
  VEntry *first;
  VEntry *last;
};

/* --- arena ---------------------------------------------------------- */

/* Allocate zeroed bytes that live until `arena_reset`. Never returns
 * NULL: allocation failure is fatal, because a library that limps on
 * after it cannot be reasoned about and the corpus cannot express it. */
void *arena_alloc(size_t size);
char *arena_strdup(const char *s);
char *arena_strndup(const char *s, size_t n);
/* Free EVERYTHING. Call between corpus entries, never inside one. */
void arena_reset(void);

/* --- construction --------------------------------------------------- */

Value *vnull(void);
Value *vbool(bool b);
Value *vnum(double n);
Value *vstr(const char *s);
Value *vlist(void);
Value *vmap(void);

/* --- access --------------------------------------------------------- */

bool visnull(const Value *v);
bool vismap(const Value *v);
bool vislist(const Value *v);
bool visstr(const Value *v);
bool visnum(const Value *v);
bool visbool(const Value *v);

/* `get` answers NULL for a missing key AND for a key holding JSON null;
 * `has` distinguishes them, which is what §9.1's "an authored null is
 * not an absent key" needs. */
Value *vget(const Value *m, const char *key);
bool vhas(const Value *m, const char *key);
void vset(Value *m, const char *key, Value *val);
void vdel(Value *m, const char *key);

Value *vat(const Value *l, size_t i);
void vpush(Value *l, Value *item);
size_t vlen(const Value *v);

const char *vasstr(const Value *v);
double vasnum(const Value *v);
bool vasbool(const Value *v);

/* Keys in INSERTION order. */
size_t vkeys(const Value *m, const char ***out);
/* Keys SORTED by byte order — §4 rule 4's deterministic walk. */
size_t vsortedkeys(const Value *m, const char ***out);

/* §4 rule 4: truthiness is JSON's, not C's. */
bool vtruthy(const Value *v);

/* Deep equality INCLUDING JSON type, which is the half that matters:
 * half the ports are written in languages whose `==` says `true == 1`,
 * and `capability/match` exists to catch exactly that. */
bool vsame(const Value *a, const Value *b);

Value *vclone(const Value *v);

/* --- json ----------------------------------------------------------- */

/* Parse, or NULL with *err set to a message. */
Value *vparse(const char *text, const char **err);
/* Canonical JSON, keys in SORTED order so two values that are `vsame`
 * render identically — the corpus compares rendered forms in places. */
const char *vjson(const Value *v);

/* Numbers render as integers when they are integral, which is what the
 * corpus's expected values look like. */
const char *vnumstr(double n);

#endif
