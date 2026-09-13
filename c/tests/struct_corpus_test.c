/* Voxgig Struct corpus driver — C port, on the VENDORED @voxgig/omni
 * runner (tests/vendor/omni, driven through tests/omni_resolver.h).
 *
 * Every `struct.<category>.<name>` section of the shared corpus
 * (.sdk/test/test.json) is run by omni itself: omni resolves the section,
 * normalises its values, calls the subject once per entry and compares
 * `out` / `match` / `err`. The hand-written engine this file used to call
 * (tests/runner.h run_subject) is retired; the subjects below crossed over
 * verbatim, because the resolver keeps their signature.
 *
 * Two behaviours changed with the engine, both deliberately:
 *
 *   * A MISSING OR EMPTY SECTION IS NOW A FAILURE. Six `sentinels.*`
 *     sections had been renamed to `struct.nullsem` in the corpus; the old
 *     runner scored them a silent 0/0 and nullsem itself went unrun. The
 *     five real nullsem sections (33 entries) are driven below, and any
 *     section that resolves to nothing is reported OUT LOUD.
 *
 *   * `match` IS CHECKED. The old engine ignored it, so
 *     struct.minor.setpath's "the subject mutated its argument" assertions
 *     and struct.merge.integrity's "the subject did NOT" assertions were
 *     dead. omni checks both (see decision 3 in omni_resolver.h).
 *
 * SCOREBOARD. omni reports pass/fail per SET, stopping at the first
 * failing entry, so per-entry credit is no longer knowable. Each row
 * therefore carries the number of cases the section HOLDS — the count that
 * proves the corpus still runs — plus its pass/fail.
 */

#include "omni_resolver.h"
#include "voxgig_struct.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The shared corpus, compiled by the project build. Relative to the target
 * root, which is where the Makefile runs each test binary from. */
#define TEST_JSON_FILE "../.sdk/test/test.json"

static omni_pool* POOL = NULL;
static omni_runpack* PACK = NULL;

/* Scoreboard: one row per corpus section. */
typedef struct slot {
  char* name;
  size_t cases;
  int failed;
  char* err;
} slot;

static slot* SB = NULL;
static size_t SB_LEN = 0;
static size_t SB_CAP = 0;

static void sb_add(const char* name, size_t cases, int failed, const char* err) {
  if (SB_LEN + 1 > SB_CAP) {
    size_t nc = SB_CAP == 0 ? 64 : SB_CAP * 2;
    SB = (slot*)realloc(SB, nc * sizeof(slot));
    SB_CAP = nc;
  }
  SB[SB_LEN].name = strdup(name);
  SB[SB_LEN].cases = cases;
  SB[SB_LEN].failed = failed;
  SB[SB_LEN].err = err ? strdup(err) : NULL;
  SB_LEN++;
}

/* Resolve `struct.<cat>.<name>`. NULL (with the reason recorded) when the
 * corpus does not carry it. */
static omni_json* section(const char* cat, const char* name, const char* full) {
  omni_json* cats = omni_set(PACK, cat);
  omni_json* spec;
  if (!omni_ismap(cats)) {
    sb_add(full, 0, 1, "corpus category missing - check .sdk/test/struct/");
    return NULL;
  }
  spec = omni_map_get(cats, name);
  if (!omni_ismap(spec)) {
    sb_add(full, 0, 1, "corpus section missing - check .sdk/test/struct/");
    return NULL;
  }
  return spec;
}

/* Run one corpus section through omni. */
static void run(const char* cat, const char* name, int nullflag, omnivx_subject_fn fn, void* ud) {
  char full[256];
  omni_json* spec;
  size_t cases;
  char* err = NULL;
  int failed;

  snprintf(full, sizeof(full), "%s.%s", cat, name);

  spec = section(cat, name, full);
  if (NULL == spec) {
    return;
  }

  cases = omnivx_setsize(spec);
  if (0 == cases) {
    sb_add(full, 0, 1, "corpus section is EMPTY - zero cases would run");
    return;
  }

  failed =
      omni_runsetflags(PACK, spec, omnivx_flags(nullflag, full), omnivx_subject(POOL, fn, ud), &err);
  sb_add(full, cases, failed, err);
}

/* `struct.merge.basic` and `struct.inject.basic` are authored as a bare
 * {in, out} node with no `set`, so the old runner scored them 0/0 and
 * asserted nothing. Wrap each as a one-entry set. */
static void run_one(const char* cat, const char* name, int nullflag, omnivx_subject_fn fn,
                    void* ud) {
  char full[256];
  omni_json* entry;
  omni_json* spec;
  char* err = NULL;
  int failed;

  snprintf(full, sizeof(full), "%s.%s", cat, name);

  entry = section(cat, name, full);
  if (NULL == entry) {
    return;
  }
  if (omni_isabsent(omni_map_get(entry, "in")) && omni_isabsent(omni_map_get(entry, "out"))) {
    sb_add(full, 0, 1, "corpus section is neither a set nor an {in,out} entry");
    return;
  }

  spec = omnivx_oneset(POOL, entry);
  failed =
      omni_runsetflags(PACK, spec, omnivx_flags(nullflag, full), omnivx_subject(POOL, fn, ud), &err);
  sb_add(full, 1, failed, err);
}


/* Helpers. */
/* Raw map lookup for runner field extraction. Unlike voxgig_getprop (Group A,
 * which treats null at a key as "no value"), this returns the literal stored
 * value — including null — so tests for Group B functions like stringify and
 * pad receive their corpus input verbatim. */
static voxgig_value* getp(voxgig_value* in, const char* key) {
  if (!voxgig_is_map(in))
    return voxgig_new_undef();
  voxgig_value* v = voxgig_map_get(voxgig_as_map(in), key);
  return v ? voxgig_retain(v) : voxgig_new_undef();
}

/* Subject implementations. */
static voxgig_value* subj_isnode(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_new_bool(voxgig_isnode(in));
}
static voxgig_value* subj_ismap(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_new_bool(voxgig_ismap(in));
}
static voxgig_value* subj_islist(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_new_bool(voxgig_islist(in));
}
static voxgig_value* subj_iskey(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_new_bool(voxgig_iskey(in));
}
static voxgig_value* subj_isempty(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_new_bool(voxgig_isempty(in));
}
static voxgig_value* subj_isfunc(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_new_bool(voxgig_isfunc(in));
}
static voxgig_value* subj_typify(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_new_int(voxgig_typify(in));
}
static voxgig_value* subj_typename(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  if (voxgig_is_int(in))
    return voxgig_new_string(voxgig_typename((int)voxgig_as_int(in)));
  return voxgig_new_string(voxgig_typename(voxgig_typify(in)));
}
static voxgig_value* subj_clone(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_clone(in);
}
static voxgig_value* subj_size(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_new_int(voxgig_size(in));
}
static voxgig_value* subj_strkey(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  char* s = voxgig_strkey(in);
  voxgig_value* v = voxgig_new_string(s);
  free(s);
  return v;
}
static voxgig_value* subj_keysof(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_strvec ks = voxgig_keysof(in);
  voxgig_value* out = voxgig_new_list();
  for (size_t i = 0; i < ks.len; i++)
    voxgig_list_push(voxgig_as_list(out), voxgig_new_string(ks.data[i]));
  voxgig_strvec_free(&ks);
  return out;
}
static voxgig_value* subj_items(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_items_v(in);
}
static voxgig_value* subj_haskey(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* src = getp(in, "src");
  voxgig_value* key = getp(in, "key");
  bool r = voxgig_haskey(src, key);
  voxgig_release(src);
  voxgig_release(key);
  return voxgig_new_bool(r);
}
/* `alt` is taken by LITERAL presence (voxgig_map_get), not by voxgig_haskey:
 * haskey is Group A and reads a stored null as "no value", which would
 * collapse `{alt: null}` (pass null as the alternative) into "no alt given"
 * — a distinction minor.getprop and struct.nullsem both assert on. */
static voxgig_value* subj_getprop(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* key = getp(in, "key");
  /* getp, not voxgig_getprop: fetching the alternative must not itself
   * apply Group A, or `{alt: null}` would arrive as UNDEF. */
  voxgig_value* alt =
      (voxgig_is_map(in) && voxgig_map_get(voxgig_as_map(in), "alt")) ? getp(in, "alt") : NULL;
  voxgig_value* r = voxgig_getprop(val, key, alt);
  voxgig_release(val);
  voxgig_release(key);
  voxgig_release(alt);
  return r;
}
static voxgig_value* subj_getelem(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* key = getp(in, "key");
  /* getp, not voxgig_getprop: fetching the alternative must not itself
   * apply Group A, or `{alt: null}` would arrive as UNDEF. */
  voxgig_value* alt =
      (voxgig_is_map(in) && voxgig_map_get(voxgig_as_map(in), "alt")) ? getp(in, "alt") : NULL;
  voxgig_value* r = voxgig_getelem(val, key, alt);
  voxgig_release(val);
  voxgig_release(key);
  voxgig_release(alt);
  return r;
}
static voxgig_value* subj_setprop(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* parent = getp(in, "parent");
  if (!parent || voxgig_is_undef(parent)) {
    voxgig_release(parent);
    parent = voxgig_new_null();
  }
  voxgig_value* key = getp(in, "key");
  voxgig_value* val = getp(in, "val");
  voxgig_value* r = voxgig_setprop(parent, key, val);
  voxgig_value* ret = r ? voxgig_retain(r) : voxgig_new_undef();
  voxgig_release(parent);
  voxgig_release(key);
  voxgig_release(val);
  return ret;
}
static voxgig_value* subj_delprop(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* parent = getp(in, "parent");
  if (!parent || voxgig_is_undef(parent)) {
    voxgig_release(parent);
    parent = voxgig_new_null();
  }
  voxgig_value* key = getp(in, "key");
  voxgig_value* r = voxgig_delprop(parent, key);
  voxgig_value* ret = r ? voxgig_retain(r) : voxgig_new_undef();
  voxgig_release(parent);
  voxgig_release(key);
  return ret;
}
static voxgig_value* subj_stringify(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* max = getp(in, "max");
  int m = -1;
  if (voxgig_is_int(max))
    m = (int)voxgig_as_int(max);
  char* s = voxgig_stringify(val, m);
  voxgig_value* r = voxgig_new_string(s);
  free(s);
  voxgig_release(val);
  voxgig_release(max);
  return r;
}
static voxgig_value* subj_jsonify(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* flags = getp(in, "flags");
  char* s = voxgig_jsonify(val, flags);
  voxgig_value* r = voxgig_new_string(s);
  free(s);
  voxgig_release(val);
  voxgig_release(flags);
  return r;
}
static voxgig_value* subj_pathify(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* path = getp(in, "path");
  voxgig_value* from = getp(in, "from");
  voxgig_value* to = getp(in, "to");
  int f = voxgig_is_int(from) ? (int)voxgig_as_int(from) : 0;
  int t = voxgig_is_int(to) ? (int)voxgig_as_int(to) : 0;
  char* s = voxgig_pathify(path, f, t);
  voxgig_value* r = voxgig_new_string(s);
  free(s);
  voxgig_release(path);
  voxgig_release(from);
  voxgig_release(to);
  return r;
}
static voxgig_value* subj_escre(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  char* s = voxgig_escre(in);
  voxgig_value* r = voxgig_new_string(s);
  free(s);
  return r;
}
static voxgig_value* subj_escurl(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  char* s = voxgig_escurl(in);
  voxgig_value* r = voxgig_new_string(s);
  free(s);
  return r;
}
static voxgig_value* subj_join(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* sep = getp(in, "sep");
  voxgig_value* url = getp(in, "url");
  char* s = voxgig_join_v(val, sep, url);
  voxgig_value* r = voxgig_new_string(s);
  free(s);
  voxgig_release(val);
  voxgig_release(sep);
  voxgig_release(url);
  return r;
}
static voxgig_value* subj_flatten(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* depth = getp(in, "depth");
  voxgig_value* r = voxgig_flatten(val, depth);
  voxgig_release(val);
  voxgig_release(depth);
  return r;
}

static bool gt3(voxgig_value* pair, void* ud) {
  (void)ud;
  voxgig_value* one = voxgig_new_int(1);
  voxgig_value* v = voxgig_getprop(pair, one, NULL);
  voxgig_release(one);
  bool ok = voxgig_is_number(v) && voxgig_as_double(v) > 3;
  voxgig_release(v);
  return ok;
}
static bool lt3(voxgig_value* pair, void* ud) {
  (void)ud;
  voxgig_value* one = voxgig_new_int(1);
  voxgig_value* v = voxgig_getprop(pair, one, NULL);
  voxgig_release(one);
  bool ok = voxgig_is_number(v) && voxgig_as_double(v) < 3;
  voxgig_release(v);
  return ok;
}
static voxgig_value* subj_filter(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* checkk = voxgig_new_string("check");
  voxgig_value* check = voxgig_getprop(in, checkk, NULL);
  voxgig_release(checkk);
  voxgig_itemcheck_fn pred = lt3;
  if (voxgig_is_string(check) && strcmp(voxgig_as_string(check), "gt3") == 0)
    pred = gt3;
  voxgig_value* r = voxgig_filter(val, pred, NULL);
  voxgig_release(val);
  voxgig_release(check);
  return r;
}
static voxgig_value* subj_slice(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* start = getp(in, "start");
  voxgig_value* end = getp(in, "end");
  voxgig_value* r = voxgig_slice(val, start, end, false);
  voxgig_release(val);
  voxgig_release(start);
  voxgig_release(end);
  return r;
}
static voxgig_value* subj_pad(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* pd = getp(in, "pad");
  voxgig_value* ch = getp(in, "char");
  char* s = voxgig_pad(val, pd, ch);
  voxgig_value* r = voxgig_new_string(s);
  free(s);
  voxgig_release(val);
  voxgig_release(pd);
  voxgig_release(ch);
  return r;
}
static voxgig_value* subj_setpath(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* store = getp(in, "store");
  voxgig_value* path = getp(in, "path");
  voxgig_value* val = getp(in, "val");
  voxgig_value* r = voxgig_setpath(store, path, val, NULL);
  voxgig_value* ret = r ? voxgig_retain(r) : voxgig_new_undef();
  voxgig_release(store);
  voxgig_release(path);
  voxgig_release(val);
  return ret;
}

/* walk depth subject: builds a parallel deep tree, controlled by maxdepth. */
typedef struct walk_depth_state {
  voxgig_value* top;
  voxgig_value* cur;
} walk_depth_state;

static voxgig_value* walk_depth_cb(voxgig_value* key, voxgig_value* val, voxgig_value* parent,
                                   voxgig_value* path, void* ud) {
  (void)parent;
  (void)path;
  walk_depth_state* st = (walk_depth_state*)ud;
  if (!key || voxgig_is_undef(key) || voxgig_isnode(val)) {
    voxgig_value* child = voxgig_is_list(val) ? voxgig_new_list() : voxgig_new_map();
    if (!key || voxgig_is_undef(key)) {
      voxgig_release(st->top);
      st->top = child;
      st->cur = child;
    } else {
      voxgig_setprop(st->cur, key, child);
      st->cur = child;
    }
  } else {
    voxgig_setprop(st->cur, key, val);
  }
  return voxgig_retain(val);
}
static voxgig_value* subj_walk_depth(voxgig_value* in, char** err, void* ud) {
  (void)err;
  (void)ud;
  voxgig_value* src = getp(in, "src");
  voxgig_value* mdv = getp(in, "maxdepth");
  int md = voxgig_is_int(mdv) ? (int)voxgig_as_int(mdv) : VOXGIG_MAXDEPTH;
  walk_depth_state st = {NULL, NULL};
  voxgig_value* w = voxgig_walk(src, walk_depth_cb, NULL, md, &st);
  voxgig_release(w);
  voxgig_release(src);
  voxgig_release(mdv);
  voxgig_value* out = st.top ? st.top : voxgig_new_map();
  return out;
}

/* getpath relative. */
static voxgig_value* subj_getpath_relative(voxgig_value* in, char** err, void* ud) {
  (void)err;
  (void)ud;
  voxgig_value* store = getp(in, "store");
  voxgig_value* path = getp(in, "path");
  voxgig_injection* inj = voxgig_inj_new(NULL, NULL);
  inj->mode = 0;
  /* Apply dparent / dpath / base from input if present. */
  voxgig_value* dparent = getp(in, "dparent");
  if (dparent && !voxgig_is_undef(dparent)) {
    voxgig_release(inj->dparent);
    inj->dparent = dparent;
  } else {
    voxgig_release(dparent);
  }
  voxgig_value* dpath = getp(in, "dpath");
  if (voxgig_is_list(dpath)) {
    voxgig_strvec_clear(&inj->dpath);
    voxgig_list* l = voxgig_as_list(dpath);
    for (size_t i = 0; i < l->len; i++) {
      char* s = voxgig_strkey(l->items[i]);
      voxgig_strvec_push(&inj->dpath, s);
      free(s);
    }
  } else if (voxgig_is_string(dpath)) {
    voxgig_strvec_clear(&inj->dpath);
    const char* s = voxgig_as_string(dpath);
    size_t n = voxgig_string_len(dpath);
    size_t i = 0;
    while (i <= n) {
      size_t j = i;
      while (j < n && s[j] != '.')
        j++;
      voxgig_strvec_push_n(&inj->dpath, s + i, j - i);
      i = j + 1;
      if (j == n)
        break;
    }
  }
  voxgig_release(dpath);
  voxgig_value* base = getp(in, "base");
  if (voxgig_is_string(base)) {
    free(inj->base);
    inj->base = strdup(voxgig_as_string(base));
  }
  voxgig_release(base);
  voxgig_value* r = voxgig_getpath(store, path, inj);
  voxgig_inj_free(inj);
  voxgig_release(store);
  voxgig_release(path);
  return r;
}

/* getpath special: an `inj` map carries key/meta/dparent/dpath. Mirrors the
 * cpp port's getpath.special dispatch. */
static voxgig_value* subj_getpath_special(voxgig_value* in, char** err, void* ud) {
  (void)err;
  (void)ud;
  voxgig_value* store = getp(in, "store");
  voxgig_value* path = getp(in, "path");
  voxgig_value* injv = getp(in, "inj");
  if (!voxgig_is_map(injv)) {
    voxgig_value* r = voxgig_getpath(store, path, NULL);
    voxgig_release(store);
    voxgig_release(path);
    voxgig_release(injv);
    return r;
  }
  voxgig_injection* inj = voxgig_inj_new(NULL, NULL);
  inj->mode = 0;
  voxgig_value* k = getp(injv, "key");
  if (voxgig_is_string(k)) {
    free(inj->key);
    inj->key = strdup(voxgig_as_string(k));
  }
  voxgig_release(k);
  voxgig_value* m = getp(injv, "meta");
  if (voxgig_is_map(m)) {
    voxgig_release(inj->meta);
    inj->meta = voxgig_retain(m);
  }
  voxgig_release(m);
  voxgig_value* dparent = getp(injv, "dparent");
  if (dparent && !voxgig_is_undef(dparent)) {
    voxgig_release(inj->dparent);
    inj->dparent = dparent;
  } else {
    voxgig_release(dparent);
  }
  voxgig_value* dpath = getp(injv, "dpath");
  if (voxgig_is_list(dpath)) {
    voxgig_strvec_clear(&inj->dpath);
    voxgig_list* l = voxgig_as_list(dpath);
    for (size_t i = 0; i < l->len; i++) {
      char* s = voxgig_strkey(l->items[i]);
      voxgig_strvec_push(&inj->dpath, s);
      free(s);
    }
  }
  voxgig_release(dpath);
  voxgig_value* r = voxgig_getpath(store, path, inj);
  voxgig_inj_free(inj);
  voxgig_release(store);
  voxgig_release(path);
  voxgig_release(injv);
  return r;
}

/* getpath handler: store gets a $FOO injector returning "foo"; a custom handler
 * invokes the injector. Mirrors perl t/struct.t getpath.handler dispatch. */
static voxgig_value* foo_injector(voxgig_injection* inj, voxgig_value* val, const char* ref,
                                  voxgig_value* store, void* ud) {
  (void)inj;
  (void)val;
  (void)ref;
  (void)store;
  (void)ud;
  return voxgig_new_string("foo");
}
static voxgig_value* handler_invoke(voxgig_injection* inj, voxgig_value* val, const char* ref,
                                    voxgig_value* store, void* ud) {
  (void)inj;
  (void)ref;
  (void)ud;
  /* Custom handler: invoke the injector value directly (perl: $val->()). */
  if (voxgig_is_injector(val))
    return val->as.fn.fn.inj(inj, val, ref, store, val->as.fn.ud);
  return val ? voxgig_retain(val) : voxgig_new_undef();
}
static voxgig_value* subj_getpath_handler(voxgig_value* in, char** err, void* ud) {
  (void)err;
  (void)ud;
  voxgig_value* store_in = getp(in, "store");
  voxgig_value* path = getp(in, "path");
  /* Build { '$TOP': store, '$FOO': <injector> }. */
  voxgig_value* store = voxgig_new_map();
  voxgig_map_set(voxgig_as_map(store), "$TOP",
                 store_in ? voxgig_retain(store_in) : voxgig_new_null());
  voxgig_map_set(voxgig_as_map(store), "$FOO", voxgig_new_injector(foo_injector, NULL));
  voxgig_injection* inj = voxgig_inj_new(NULL, NULL);
  inj->mode = 0;
  voxgig_release(inj->handler_val);
  inj->handler_val = voxgig_new_injector(handler_invoke, NULL);
  voxgig_value* r = voxgig_getpath(store, path, inj);
  voxgig_inj_free(inj);
  voxgig_release(store);
  voxgig_release(store_in);
  voxgig_release(path);
  return r;
}

/* The struct-corpus null modifier (was runner.h's unused null_substitute):
 * under the default null flag omni rewrites every JSON null in the section
 * to the "__NULL__" marker, so a resolved null arrives as that text. A bare
 * marker becomes a real null again; a marker EMBEDDED in a longer string
 * becomes the literal word "null", which is what `inject.string` asserts
 * ("`an`x" over {an: null} renders "nullx"). */
static void null_modifier(voxgig_value* val, voxgig_value* key, voxgig_value* parent,
                          voxgig_injection* inj, voxgig_value* store, void* ud) {
  (void)inj;
  (void)store;
  (void)ud;
  if (!voxgig_is_string(val) || !parent || !key)
    return;
  {
    const char* s = voxgig_as_string(val);
    if (0 == strcmp(s, "__NULL__")) {
      voxgig_setprop(parent, key, voxgig_new_null());
      return;
    }
    if (NULL != strstr(s, "__NULL__")) {
      char* rep = voxgig_replace_str(s, "__NULL__", "null");
      voxgig_value* rv = voxgig_new_string(rep);
      free(rep);
      voxgig_setprop(parent, key, rv);
      voxgig_release(rv);
    }
  }
}

/* Walk subjects. */
static voxgig_value* walk_basic_cb(voxgig_value* key, voxgig_value* val, voxgig_value* parent,
                                   voxgig_value* path, void* ud) {
  (void)key;
  (void)parent;
  (void)ud;
  if (voxgig_is_string(val)) {
    char* buf = NULL;
    size_t len = 0, cap = 0;
    const char* s = voxgig_as_string(val);
    size_t sl = voxgig_string_len(val);
    /* val + "~" + path.join(".") */
    cap = sl + 16;
    buf = (char*)malloc(cap);
    memcpy(buf, s, sl);
    len = sl;
    buf[len++] = '~';
    voxgig_list* pl = voxgig_as_list(path);
    for (size_t i = 0; i < pl->len; i++) {
      if (i > 0) {
        if (len + 1 >= cap) {
          cap *= 2;
          buf = (char*)realloc(buf, cap);
        }
        buf[len++] = '.';
      }
      const char* ps = voxgig_as_string(pl->items[i]);
      size_t psl = voxgig_string_len(pl->items[i]);
      if (len + psl + 1 >= cap) {
        while (cap < len + psl + 1)
          cap *= 2;
        buf = (char*)realloc(buf, cap);
      }
      memcpy(buf + len, ps, psl);
      len += psl;
    }
    buf[len] = '\0';
    voxgig_value* r = voxgig_new_string(buf);
    free(buf);
    return r;
  }
  return voxgig_retain(val);
}
static voxgig_value* subj_walk_basic(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_walk(in, walk_basic_cb, NULL, VOXGIG_MAXDEPTH, NULL);
}

/* Merge subjects. */
static voxgig_value* subj_merge(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  return voxgig_merge(in, VOXGIG_MAXDEPTH);
}
static voxgig_value* subj_merge_depth(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* depth = getp(in, "depth");
  int d = voxgig_is_int(depth) ? (int)voxgig_as_int(depth) : VOXGIG_MAXDEPTH;
  voxgig_value* r = voxgig_merge(val, d);
  voxgig_release(val);
  voxgig_release(depth);
  return r;
}

/* getpath subjects. */
static voxgig_value* subj_getpath_basic(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* store = getp(in, "store");
  voxgig_value* path = getp(in, "path");
  voxgig_value* r = voxgig_getpath(store, path, NULL);
  voxgig_release(store);
  voxgig_release(path);
  return r;
}

/* inject subjects. */
static voxgig_value* subj_inject(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* store = getp(in, "store");
  voxgig_value* r = voxgig_inject(val, store, NULL);
  voxgig_release(val);
  voxgig_release(store);
  return r;
}
static voxgig_value* subj_inject_nullmod(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* val = getp(in, "val");
  voxgig_value* store = getp(in, "store");
  voxgig_injection* inj = voxgig_inj_new(NULL, NULL);
  inj->mode = 0;
  voxgig_release(inj->modify_val);
  inj->modify_val = voxgig_new_modify(null_modifier, NULL);
  voxgig_value* r = voxgig_inject(val, store, inj);
  voxgig_inj_free(inj);
  voxgig_release(val);
  voxgig_release(store);
  return r;
}

/* transform subjects. */
static voxgig_value* subj_transform(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* data = getp(in, "data");
  voxgig_value* spec = getp(in, "spec");
  voxgig_value* r = voxgig_transform(data, spec, NULL);
  voxgig_release(data);
  voxgig_release(spec);
  return r;
}

/* Helper to collect errs from a validate/transform call. */
static char* join_errs(voxgig_value* errs) {
  if (!voxgig_is_list(errs))
    return NULL;
  voxgig_list* l = voxgig_as_list(errs);
  if (l->len == 0)
    return NULL;
  size_t cap = 256, len = 0;
  char* buf = malloc(cap);
  buf[0] = '\0';
  for (size_t i = 0; i < l->len; i++) {
    if (!voxgig_is_string(l->items[i]))
      continue;
    const char* s = voxgig_as_string(l->items[i]);
    size_t sl = strlen(s);
    if (len + sl + 8 > cap) {
      while (len + sl + 8 > cap)
        cap *= 2;
      buf = realloc(buf, cap);
    }
    if (i > 0) {
      strcat(buf, " | ");
      len += 3;
    }
    strcat(buf, s);
    len += sl;
  }
  return buf;
}

/* validate subjects. */
static voxgig_value* subj_validate(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* data = getp(in, "data");
  voxgig_value* spec = getp(in, "spec");
  /* Build a config bag with errs to collect. */
  voxgig_injection* sub = voxgig_inj_new(NULL, NULL);
  sub->mode = 0;
  voxgig_release(sub->errs);
  sub->errs = voxgig_new_list();
  voxgig_value* r = voxgig_validate(data, spec, sub);
  /* If errs collected, set err. */
  if (voxgig_list_len(voxgig_as_list(sub->errs)) > 0) {
    *err = join_errs(sub->errs);
  }
  voxgig_inj_free(sub);
  voxgig_release(data);
  voxgig_release(spec);
  return r;
}

/* select subjects. */
static voxgig_value* subj_select(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  voxgig_value* obj = getp(in, "obj");
  voxgig_value* query = getp(in, "query");
  voxgig_value* r = voxgig_select(obj, query);
  voxgig_release(obj);
  voxgig_release(query);
  return r;
}

/* Category to file map (for scoreboard grouping). */
static const char* category_to_file(const char* cat) {
  if (strcmp(cat, "minor") == 0)
    return "minor.jsonic";
  if (strcmp(cat, "walk") == 0)
    return "walk.jsonic";
  if (strcmp(cat, "merge") == 0)
    return "merge.jsonic";
  if (strcmp(cat, "getpath") == 0)
    return "getpath.jsonic";
  if (strcmp(cat, "inject") == 0)
    return "inject.jsonic";
  if (strcmp(cat, "transform") == 0)
    return "transform.jsonic";
  if (strcmp(cat, "validate") == 0)
    return "validate.jsonic";
  if (strcmp(cat, "select") == 0)
    return "select.jsonic";
  if (strcmp(cat, "nullsem") == 0)
    return "nullsem.jsonic";
  return cat;
}

int main(void) {
  char* err = NULL;
  omni_runner* runner;
  int failed = 0;
  size_t cases = 0;
  size_t i;
  FILE* f;

  POOL = omni_pool_new();

  runner = omni_make_runner(POOL, TEST_JSON_FILE, NULL, NULL, &err);
  if (NULL == runner) {
    fprintf(stderr, "struct corpus: %s\n", NULL == err ? "cannot make runner" : err);
    return 1;
  }

  PACK = omni_runner_run(runner, "struct", NULL, &err);
  if (NULL == PACK || !omni_ismap(omni_spec(PACK))) {
    fprintf(stderr, "struct corpus: struct section not found in %s\n", TEST_JSON_FILE);
    return 1;
  }

  /* The `null` flag of each section is the shared one: with it, omni
   * rewrites every JSON null in the section to the "__NULL__" marker
   * before the subject sees it; without it, nulls stay null. It is a
   * property of the CASES, so it matches the reference harness section for
   * section. */

  /* minor */
  run("minor", "isnode", 1, subj_isnode, NULL);
  run("minor", "ismap", 1, subj_ismap, NULL);
  run("minor", "islist", 1, subj_islist, NULL);
  run("minor", "iskey", 0, subj_iskey, NULL);
  run("minor", "strkey", 0, subj_strkey, NULL);
  run("minor", "isempty", 0, subj_isempty, NULL);
  run("minor", "isfunc", 1, subj_isfunc, NULL);
  run("minor", "typify", 0, subj_typify, NULL);
  run("minor", "typename", 1, subj_typename, NULL);
  run("minor", "clone", 0, subj_clone, NULL);
  run("minor", "size", 0, subj_size, NULL);
  run("minor", "keysof", 1, subj_keysof, NULL);
  run("minor", "items", 1, subj_items, NULL);
  run("minor", "haskey", 0, subj_haskey, NULL);
  run("minor", "getprop", 0, subj_getprop, NULL);
  run("minor", "getelem", 0, subj_getelem, NULL);
  run("minor", "setprop", 1, subj_setprop, NULL);
  run("minor", "delprop", 1, subj_delprop, NULL);
  run("minor", "stringify", 0, subj_stringify, NULL);
  run("minor", "jsonify", 0, subj_jsonify, NULL);
  run("minor", "pathify", 0, subj_pathify, NULL);
  run("minor", "escre", 1, subj_escre, NULL);
  run("minor", "escurl", 1, subj_escurl, NULL);
  run("minor", "join", 0, subj_join, NULL);
  run("minor", "flatten", 1, subj_flatten, NULL);
  run("minor", "filter", 1, subj_filter, NULL);
  run("minor", "slice", 0, subj_slice, NULL);
  run("minor", "pad", 0, subj_pad, NULL);
  run("minor", "setpath", 0, subj_setpath, NULL);

  /* walk */
  run("walk", "basic", 1, subj_walk_basic, NULL);
  run("walk", "depth", 0, subj_walk_depth, NULL);

  /* merge */
  run_one("merge", "basic", 1, subj_merge, NULL);
  run("merge", "cases", 1, subj_merge, NULL);
  run("merge", "array", 1, subj_merge, NULL);
  run("merge", "integrity", 1, subj_merge, NULL);
  run("merge", "depth", 1, subj_merge_depth, NULL);

  /* getpath */
  run("getpath", "basic", 1, subj_getpath_basic, NULL);
  run("getpath", "relative", 1, subj_getpath_relative, NULL);
  run("getpath", "special", 1, subj_getpath_special, NULL);
  run("getpath", "handler", 1, subj_getpath_handler, NULL);

  /* nullsem — does a PRESENT key holding a JSON null read as "no value"?
   * Every lane runs {null: 0}: with the flag on, the runner rewrites each
   * null to "__NULL__" and the section would assert nothing about null at
   * all. This is the section the six vacuous `sentinels.*` rows hid. */
  run("nullsem", "getprop", 0, subj_getprop, NULL);
  run("nullsem", "getelem", 0, subj_getelem, NULL);
  run("nullsem", "getpath", 0, subj_getpath_basic, NULL);
  run("nullsem", "haskey", 0, subj_haskey, NULL);
  run("nullsem", "keysof", 0, subj_keysof, NULL);

  /* inject */
  run_one("inject", "basic", 1, subj_inject, NULL);
  run("inject", "string", 1, subj_inject_nullmod, NULL);
  run("inject", "deep", 1, subj_inject, NULL);

  /* transform */
  run("transform", "paths", 1, subj_transform, NULL);
  run("transform", "cmds", 1, subj_transform, NULL);
  run("transform", "each", 1, subj_transform, NULL);
  run("transform", "pack", 1, subj_transform, NULL);
  run("transform", "ref", 1, subj_transform, NULL);

  /* validate */
  run("validate", "basic", 0, subj_validate, NULL);
  run("validate", "invalid", 0, subj_validate, NULL);
  run("validate", "child", 1, subj_validate, NULL);
  run("validate", "one", 1, subj_validate, NULL);
  run("validate", "exact", 1, subj_validate, NULL);

  /* select */
  run("select", "basic", 1, subj_select, NULL);
  run("select", "operators", 1, subj_select, NULL);
  run("select", "edge", 1, subj_select, NULL);
  run("select", "alts", 1, subj_select, NULL);

  /* Aggregate scoreboard. */
  printf("\n========= STRUCT CORPUS SCOREBOARD =========\n");
  for (i = 0; i < SB_LEN; i++) {
    printf("  %-30s %-4s %4zu cases\n", SB[i].name, SB[i].failed ? "FAIL" : "ok", SB[i].cases);
    cases += SB[i].cases;
    failed += SB[i].failed ? 1 : 0;
  }
  printf("  %-30s %-4s %4zu cases in %zu sections\n", "TOTAL", failed ? "FAIL" : "ok", cases,
         SB_LEN);
  printf("============================================\n");

  for (i = 0; i < SB_LEN; i++) {
    if (SB[i].failed) {
      fprintf(stderr, "\n--- %s ---\n%s\n", SB[i].name,
              NULL == SB[i].err ? "(no message)" : SB[i].err);
    }
  }

  /* Write target/corpus-scoreboard.json. Same schema as before; `passed`
   * is the section's case count when the section passed, because omni
   * stops a set at its first failure and partial credit is unknowable. */
  f = fopen("corpus-scoreboard.json", "w");
  if (f) {
    size_t passedcases = 0;
    int first = 1;
    fprintf(f, "{\n  \"files\": {\n");
    for (i = 0; i < SB_LEN; i++) {
      const char* dot = strchr(SB[i].name, '.');
      const char* cat = SB[i].name;
      char catbuf[64];
      if (dot) {
        size_t cl = (size_t)(dot - cat);
        if (cl >= sizeof(catbuf))
          cl = sizeof(catbuf) - 1;
        memcpy(catbuf, cat, cl);
        catbuf[cl] = '\0';
        cat = catbuf;
      }
      if (!first)
        fprintf(f, ",\n");
      first = 0;
      fprintf(f, "    \"%s\": {\"passed\": %zu, \"total\": %zu}", category_to_file(cat),
              SB[i].failed ? (size_t)0 : SB[i].cases, SB[i].cases);
      passedcases += SB[i].failed ? 0 : SB[i].cases;
    }
    fprintf(f, "\n  },\n  \"total\": {\"passed\": %zu, \"total\": %zu}\n}\n", passedcases, cases);
    fclose(f);
  }

  for (i = 0; i < SB_LEN; i++) {
    free(SB[i].name);
    free(SB[i].err);
  }
  free(SB);
  omni_pool_free(POOL);

  return 0 == failed ? 0 : 1;
}
