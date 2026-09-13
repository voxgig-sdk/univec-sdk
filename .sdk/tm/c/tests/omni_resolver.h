/* The corpus test runner: vendored @voxgig/omni driven through its NATIVE
 * API (omni_make_runner / omni_runner_run / omni_runsetflags, see
 * tests/vendor/omni/omni.h), adapted to the subject shapes the corpus
 * drivers already use. No compat shim is vendored: the adapter below IS
 * the whole bridge, per language, per the vendor-tag rollout
 * (docs/design/vendor-tag-rollout.md, Decision 4). It supersedes the whole
 * of the retired tests/runner.h - both its engine half (run_subject) and
 * its support half (normalize / deep_equal / brief / null_substitute,
 * subsumed by omni_deepequal / omni_matchval / omni_stringify).
 *
 * C-specific decisions, each load-bearing:
 *
 * 1. TWO VALUE MODELS, ONE BIDIRECTIONAL BRIDGE. Every other migrated
 *    target shares one value model with its omni port and needs only a
 *    sentinel swap. C does not: omni carries its OWN arena-allocated model
 *    (omni_json + omni_pool, tests/vendor/omni/json.c) while the SDK uses
 *    the refcounted voxgig_value of utility/struct. So omnivx_tovx and
 *    omnivx_tomni below convert whole values in both directions, and the
 *    ownership rule is the SDK's own (core/sdk.h): omni values are
 *    pool-owned and freed in one go by omni_pool_free; voxgig values the
 *    bridge creates for a subject are released after the call, and values
 *    the SDK pipeline builds are never released at all.
 *
 * 2. "NO ARGUMENT" AND "NULL" ARE NATIVELY DISTINCT. The corpus carries
 *    entries with no `in`, `args` or `ctx`, meaning "call the subject with
 *    NO argument". The vendored C port already distinguishes that case:
 *    omni_map_get on a missing key answers a value of type OMNI_ABSENT,
 *    omni_clone preserves it, and such an entry arrives as one OMNI_ABSENT
 *    argument. So C needs neither go's novalargs spec rewrite nor a compat
 *    shim - the ONE conversion is the sentinel swap at the call boundary:
 *    OMNI_ABSENT -> voxgig_new_undef() inbound, VOXGIG_VAL_UNDEF ->
 *    omni_absent() outbound, walked, because getpath can leave an undef
 *    inside a partially-resolved node.
 *
 * 3. THE ARGUMENT IS WRITTEN BACK. `struct.minor.setpath` asserts
 *    `match: {args: {0: {store: ...}}}` - that the subject mutated the
 *    container it was handed - and `struct.merge.integrity` asserts the
 *    opposite for merge. The bridge hands the subject a fresh voxgig copy,
 *    so after the call omnivx_writeback rewrites the CONTENTS of the omni
 *    argument node in place (its identity is preserved, because the runner
 *    also stores it as `entry.ctx`). The retired runner.h could not check
 *    either assertion: it ignored `match` entirely.
 *
 * 4. NUMBERS ARE RE-TYPED ON THE WAY IN. voxgig distinguishes integer from
 *    decimal (minor.typify / minor.typename assert on it) while omni_json
 *    holds one double. The bridge classifies an integral finite double as
 *    VOXGIG_VAL_INT, which is exactly what voxgig_parse_json_file did for
 *    a literal with no '.' and no exponent - and the shared corpus holds
 *    no integral-valued decimal literal, so the two readings agree case
 *    for case.
 *
 * 5. VALUES OMNI CANNOT EXPRESS ARE RENDERED AS voxgig's OWN JSON FORM.
 *    VAL_FUNC (injector/modify) and the SKIP/DELETE sentinels have no omni
 *    type. Rather than let them read as "absent", the bridge renders them
 *    the way voxgig_jsonify does - a function as null, a sentinel as
 *    {"`$NAME`": true} - so an assertion that meets one sees the same text
 *    it would have seen through stringify.
 *
 * 6. NO EXCEPTIONS, SO NO OmniError. omni_runset returns non-zero and sets
 *    *errout to a pool-owned message; a subject reports failure by setting
 *    its `char **err` out-param, which the bridge copies into
 *    omni_result.err. This is the one documented parity exemption for the
 *    C port (tests/vendor/omni README, c:55-56).
 *
 * 7. omni#54 GAP 1 IS PRESENT in the vendored C port: omni_jsonstr has no
 *    cycle guard. Mitigation is java's: typed SDK state is kept OUT of the
 *    entries (a corpus subject builds its typed Context at the call site
 *    and publishes only plain data back), and the bridge carries its own
 *    depth bound, OMNIVX_MAXDEPTH, so a cyclic value becomes a marker
 *    string instead of a hang.
 *
 * Header-only; every helper is `static` + unused-safe, so a test binary
 * may include it and use only part of it.
 */

#ifndef PROJECTNAME_OMNI_RESOLVER_H
#define PROJECTNAME_OMNI_RESOLVER_H

#include "vendor/omni/omni.h"
#include "voxgig_struct.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OMNIVX __attribute__((unused)) static

/* Deeper than any corpus value; a cyclic one is cut here rather than
 * followed (decision 7). */
#define OMNIVX_MAXDEPTH 64
#define OMNIVX_DEPTHMARK "__DEPTH__"

/* ---- value bridge: omni -> voxgig ---------------------------------- */

OMNIVX int omnivx_isintegral(double num) {
  /* The range test keeps the (int64_t) cast defined; outside it the value
   * can only have come from a decimal literal anyway. */
  return isfinite(num) && floor(num) == num && -9.0e18 <= num && num <= 9.0e18;
}

OMNIVX voxgig_value* omnivx_tovx_at(const omni_json* val, int depth);

OMNIVX voxgig_value* omnivx_tovx(const omni_json* val) { return omnivx_tovx_at(val, 0); }

OMNIVX voxgig_value* omnivx_tovx_at(const omni_json* val, int depth) {
  size_t at;

  if (NULL == val) {
    return voxgig_new_undef();
  }
  if (OMNIVX_MAXDEPTH < depth) {
    return voxgig_new_string(OMNIVX_DEPTHMARK);
  }

  switch (val->type) {
  case OMNI_ABSENT:
    return voxgig_new_undef();
  case OMNI_NULL:
    return voxgig_new_null();
  case OMNI_BOOL:
    return voxgig_new_bool(0 != val->boolval);
  case OMNI_NUM:
    return omnivx_isintegral(val->numval) ? voxgig_new_int((int64_t)val->numval)
                                          : voxgig_new_double(val->numval);
  case OMNI_STR:
    return voxgig_new_string(NULL == val->strval ? "" : val->strval);
  case OMNI_LIST: {
    voxgig_value* out = voxgig_new_list();
    for (at = 0; at < val->listlen; at++) {
      voxgig_list_push(voxgig_as_list(out), omnivx_tovx_at(val->list[at], depth + 1));
    }
    return out;
  }
  case OMNI_MAP: {
    voxgig_value* out = voxgig_new_map();
    for (at = 0; at < val->maplen; at++) {
      voxgig_map_set(voxgig_as_map(out), val->keys[at], omnivx_tovx_at(val->vals[at], depth + 1));
    }
    return out;
  }
  }

  return voxgig_new_undef();
}

/* ---- value bridge: voxgig -> omni ---------------------------------- */

OMNIVX omni_json* omnivx_tomni_at(omni_pool* pool, voxgig_value* val, int depth);

OMNIVX omni_json* omnivx_tomni(omni_pool* pool, voxgig_value* val) {
  return omnivx_tomni_at(pool, val, 0);
}

OMNIVX omni_json* omnivx_tomni_at(omni_pool* pool, voxgig_value* val, int depth) {
  size_t at;

  if (NULL == val) {
    return omni_absent(pool);
  }
  if (OMNIVX_MAXDEPTH < depth) {
    return omni_str(pool, OMNIVX_DEPTHMARK);
  }

  switch (val->kind) {
  case VOXGIG_VAL_UNDEF:
    return omni_absent(pool);
  case VOXGIG_VAL_NULL:
    return omni_null(pool);
  case VOXGIG_VAL_BOOL:
    return omni_bool(pool, voxgig_as_bool(val) ? 1 : 0);
  case VOXGIG_VAL_INT:
    return omni_num(pool, (double)voxgig_as_int(val));
  case VOXGIG_VAL_DOUBLE:
    return omni_num(pool, voxgig_as_double(val));
  case VOXGIG_VAL_STRING: {
    const char* str = voxgig_as_string(val);
    return omni_str(pool, NULL == str ? "" : str);
  }
  case VOXGIG_VAL_LIST: {
    voxgig_list* list = voxgig_as_list(val);
    omni_json* out = omni_list(pool);
    for (at = 0; at < list->len; at++) {
      omni_list_push(out, omnivx_tomni_at(pool, list->items[at], depth + 1));
    }
    return out;
  }
  case VOXGIG_VAL_MAP: {
    voxgig_map* map = voxgig_as_map(val);
    omni_json* out = omni_map(pool);
    for (at = 0; at < map->len; at++) {
      omni_map_set(out, map->entries[at].key,
                   omnivx_tomni_at(pool, map->entries[at].value, depth + 1));
    }
    return out;
  }
  case VOXGIG_VAL_FUNC:
    /* voxgig_jsonify renders a callable as null; so does the bridge. */
    return omni_null(pool);
  case VOXGIG_VAL_SENTINEL: {
    /* voxgig_jsonify renders a sentinel as {"`$NAME`": true}. */
    const voxgig_sentinel* sent = voxgig_as_sentinel(val);
    omni_json* out = omni_map(pool);
    char key[64];
    snprintf(key, sizeof(key), "`$%s`", (NULL != sent && NULL != sent->name) ? sent->name : "?");
    omni_map_set(out, key, omni_bool(pool, 1));
    return out;
  }
  }

  return omni_absent(pool);
}

/* ---- argument write-back (decision 3) ------------------------------ */

/* Rewrite the CONTENTS of `dst` from `src`, keeping dst's identity: the
 * runner stored that very node as the entry's `args[0]` and `ctx`, and a
 * `match` assertion reads through it. Containers only - a scalar argument
 * cannot be mutated by the subject in a way the corpus can observe. */
OMNIVX void omnivx_writeback(omni_pool* pool, omni_json* dst, voxgig_value* src) {
  size_t at;

  if (NULL == dst || NULL == src) {
    return;
  }

  if (OMNI_MAP == dst->type && voxgig_is_map(src)) {
    voxgig_map* map = voxgig_as_map(src);
    dst->maplen = 0;
    for (at = 0; at < map->len; at++) {
      omni_map_set(dst, map->entries[at].key, omnivx_tomni_at(pool, map->entries[at].value, 1));
    }
    return;
  }

  if (OMNI_LIST == dst->type && voxgig_is_list(src)) {
    voxgig_list* list = voxgig_as_list(src);
    dst->listlen = 0;
    for (at = 0; at < list->len; at++) {
      omni_list_push(dst, omnivx_tomni_at(pool, list->items[at], 1));
    }
    return;
  }
}

/* ---- subjects ------------------------------------------------------ */

/* The struct-corpus subject shape: one value in, one value out, with an
 * optional error message. Unchanged from the retired runner.h, so every
 * corpus subject in tests/struct_corpus_test.c crossed over verbatim. */
typedef voxgig_value* (*omnivx_subject_fn)(voxgig_value* in, char** err, void* ud);

typedef struct omnivx_holder {
  omni_subject sub; /* FIRST: `sub.data` points back at the holder */
  omni_pool* pool;
  omnivx_subject_fn fn;
  void* ud;
} omnivx_holder;

OMNIVX omni_result omnivx_call(omni_subject* self, omni_json** args, size_t nargs) {
  omnivx_holder* holder = (omnivx_holder*)self->data;
  omni_result out;
  voxgig_value* in;
  voxgig_value* got;
  char* err = NULL;

  out.val = NULL;
  out.err = NULL;

  /* nargs is 1 with an OMNI_ABSENT argument for a no-argument entry
   * (decision 2); nargs is 0 only for an explicit `args: []`. */
  in = 0 < nargs ? omnivx_tovx(args[0]) : voxgig_new_undef();

  got = holder->fn(in, &err, holder->ud);

  if (0 < nargs) {
    omnivx_writeback(holder->pool, args[0], in);
  }

  if (NULL != err) {
    out.err = omni_pool_strdup(holder->pool, err);
    free(err);
  } else {
    out.val = omnivx_tomni(holder->pool, got);
  }

  voxgig_release(got);
  voxgig_release(in);

  return out;
}

OMNIVX omni_subject* omnivx_subject(omni_pool* pool, omnivx_subject_fn fn, void* ud) {
  omnivx_holder* holder = (omnivx_holder*)omni_pool_alloc(pool, sizeof(omnivx_holder));
  holder->sub.call = omnivx_call;
  holder->sub.data = holder;
  holder->pool = pool;
  holder->fn = fn;
  holder->ud = ud;
  return &holder->sub;
}

/* The raw subject shape: omni values straight through. The primary corpus
 * uses it because its entries assert on `ctx`, which the subject must
 * publish back into the very omni map the runner handed it (java's
 * decision 1: contexts stay MAPS across the runner, and the typed Context
 * is built and synced at the call site). */
typedef omni_result (*omnivx_raw_fn)(omni_pool* pool, omni_json** args, size_t nargs, void* ud);

typedef struct omnivx_rawholder {
  omni_subject sub; /* FIRST */
  omni_pool* pool;
  omnivx_raw_fn fn;
  void* ud;
} omnivx_rawholder;

OMNIVX omni_result omnivx_rawcall(omni_subject* self, omni_json** args, size_t nargs) {
  omnivx_rawholder* holder = (omnivx_rawholder*)self->data;
  return holder->fn(holder->pool, args, nargs, holder->ud);
}

OMNIVX omni_subject* omnivx_rawsubject(omni_pool* pool, omnivx_raw_fn fn, void* ud) {
  omnivx_rawholder* holder = (omnivx_rawholder*)omni_pool_alloc(pool, sizeof(omnivx_rawholder));
  holder->sub.call = omnivx_rawcall;
  holder->sub.data = holder;
  holder->pool = pool;
  holder->fn = fn;
  holder->ud = ud;
  return &holder->sub;
}

/* ---- spec helpers -------------------------------------------------- */

/* How many entries a resolved test spec holds. Zero for a spec that is
 * absent, or that carries no `set` list - which the corpus drivers report
 * as a FAILURE, because a section that runs no case proves nothing. */
OMNIVX size_t omnivx_setsize(const omni_json* testspec) {
  const omni_json* set = omni_map_get(testspec, "set");
  return omni_islist(set) ? set->listlen : 0;
}

/* Wrap a bare {in, out} node - `struct.merge.basic` and
 * `struct.inject.basic` are authored that way, with no `set` - as a
 * one-entry set the runner can drive. Without this they scored 0/0 and
 * asserted nothing. */
OMNIVX omni_json* omnivx_oneset(omni_pool* pool, omni_json* entry) {
  omni_json* spec = omni_map(pool);
  omni_json* set = omni_list(pool);
  omni_list_push(set, entry);
  omni_map_set(spec, "set", set);
  return spec;
}

/* omni's flags, with the failure-message label filled in. */
OMNIVX omni_flags omnivx_flags(int donull, const char* name) {
  omni_flags flags = donull ? omni_flags_default() : omni_flags_nonull();
  flags.name = name;
  return flags;
}

#endif /* PROJECTNAME_OMNI_RESOLVER_H */
