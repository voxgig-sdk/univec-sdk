// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/config.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The declarative document (§9): normalization, and the ten-level
 * precedence ladder.
 *
 * TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
 *
 * `normalizeconfig` normalizes STRUCTURE and ENTRY KEYS. It does not
 * merge options, and cannot: §9.4 makes merge behaviour a property of
 * the definition's option SHAPE, which normalization has never seen. A
 * normalizer that flattened the option layers would make
 * `$MERGE: append` unimplementable at load time, because the layers it
 * must concatenate would already be collapsed.
 *
 * `resolveoptions` applies the ladder, and it is the only place that
 * knows the shape. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "config.h"
#include "ref.h"

/* Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
 * sort identically under all three, so only mixed input discriminates:
 * '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. */
static int bytewise(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* §9.1: reservation is all-or-nothing per NAME, so the tagged forms go
 * too. A configuration surface that can disable the thing reading it is
 * not a surface, it is a trap. */
static void checkreserved(const char *ref, Value *reserved) {
  if (!vislist(reserved) || 0 == vlen(reserved)) return;
  const char *name = refname(ref);
  for (size_t i = 0; i < vlen(reserved); i++) {
    Value *r = vat(reserved, i);
    if (visstr(r) && 0 == strcmp(vasstr(r), name)) {
      size_t sz = strlen(ref) + 48;
      char *text = (char *)arena_alloc(sz);
      snprintf(text, sz, "ref is reserved by the host: %s", ref);
      fail("plugin_ref_reserved", text, details1("ref", vstr(ref)));
    }
  }
}

/* Both document forms reduce to {ref -> entry} plus the order the form
 * implies: array POSITION for the array form, sorted refs for the map
 * form. */
typedef struct {
  Value *map;     /* ref -> entry */
  Value *order;   /* list of refs */
} Entries;

static Entries entriesof(Value *src) {
  Entries out;
  out.map = vmap();
  out.order = vlist();
  if (visnull(src)) return out;

  if (vislist(src)) {
    for (size_t i = 0; i < vlen(src); i++) {
      Value *item = vat(src, i);
      const char *ref = canonref(vget(item, "ref"));
      vset(out.map, ref, item);
      vpush(out.order, vstr(ref));
    }
    return out;
  }

  /* Map-form refs arrive as KEYS, through a different path than an
   * array element's `ref` field — and must canonicalize the same way. */
  const char **keys;
  size_t n = vkeys(src, &keys);
  for (size_t i = 0; i < n; i++) {
    vset(out.map, canonref(vstr(keys[i])), vget(src, keys[i]));
  }
  const char **canonkeys;
  size_t cn = vkeys(out.map, &canonkeys);
  if (1 < cn) qsort((void *)canonkeys, cn, sizeof(char *), bytewise);
  for (size_t i = 0; i < cn; i++) vpush(out.order, vstr(canonkeys[i]));
  return out;
}

/* PRESENT WINS, EVEN WHEN THE VALUE IS NULL. The canonical is
 * `src && undefined !== src[key]`, and in JavaScript a key holding
 * `null` passes that test — so a profile's `order: null` clears a base
 * ordering block and `active: null` over a base `active: true` is
 * falsy, and barred. Testing for non-null instead treated an authored
 * null as an absent key, which is §9.1's distinction inverted. */
static Value *pick(Value *src, const char *key, Value *dflt) {
  if (vismap(src) && vhas(src, key)) return vget(src, key);
  return dflt;
}

static bool listhas(Value *list, const char *s) {
  for (size_t i = 0; i < vlen(list); i++) {
    if (visstr(vat(list, i)) && 0 == strcmp(vasstr(vat(list, i)), s)) return true;
  }
  return false;
}

Value *normalizeconfig(Value *input) {
  Value *doc = vget(input, "doc");
  if (!vismap(doc)) doc = vmap();
  Value *keys = vget(input, "keys");
  const char *ikey = visstr(vget(keys, "instance")) ? vasstr(vget(keys, "instance")) : "instance";
  const char *dkey = visstr(vget(keys, "default")) ? vasstr(vget(keys, "default")) : "default";
  Value *reserved = vget(input, "reserved");
  Value *profile = vget(input, "profile");

  /* The rename is applied at TWO PLACES AND NO OTHERS: the document
   * root, and every profile.<name> overlay root (§9.1). A rename applied
   * only at the root would leave `profile.prod.sdk` untranslated and
   * silently drop every environment override the host depends on.
   * Recursing further would be worse: option data is the definition's. */
  Value *baseinst = vget(doc, ikey);
  Value *basedef = vget(doc, dkey);
  if (!vismap(basedef)) basedef = vmap();

  Value *overlay = NULL;
  if (visstr(profile)) {
    Value *profiles = vget(doc, "profile");
    overlay = vget(profiles, vasstr(profile));
  }
  Value *overinst = vismap(overlay) ? vget(overlay, ikey) : NULL;
  Value *overdef = vismap(overlay) ? vget(overlay, dkey) : NULL;
  if (!vismap(overdef)) overdef = vmap();

  Entries base = entriesof(baseinst);
  Entries over = entriesof(overinst);

  const char **rk;
  size_t rn = vkeys(base.map, &rk);
  for (size_t i = 0; i < rn; i++) checkreserved(rk[i], reserved);
  rn = vkeys(over.map, &rk);
  for (size_t i = 0; i < rn; i++) checkreserved(rk[i], reserved);
  rn = vkeys(basedef, &rk);
  for (size_t i = 0; i < rn; i++) checkreserved(rk[i], reserved);
  rn = vkeys(overdef, &rk);
  for (size_t i = 0; i < rn; i++) checkreserved(rk[i], reserved);

  /* A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the hard
   * way: deriving order from a partial array silently dropped
   * config-activated features. Refs in the base but absent from the
   * overlay still load, in sorted position AFTER the listed ones. A
   * profile may also INTRODUCE a ref the base never declared. */
  Value *order = vlist();
  for (size_t i = 0; i < vlen(over.order); i++) {
    const char *r = vasstr(vat(over.order, i));
    if (!listhas(order, r)) vpush(order, vstr(r));
  }
  /* The remainder keeps the BASE's own order — array position for the
   * array form, sorted refs for the map form. Re-sorting here would
   * discard an array document's positional order entirely, which is the
   * one thing the array form exists to express. */
  for (size_t i = 0; i < vlen(base.order); i++) {
    const char *r = vasstr(vat(base.order, i));
    if (!listhas(order, r)) vpush(order, vstr(r));
  }

  Value *instance = vmap();
  for (size_t i = 0; i < vlen(order); i++) {
    const char *ref = vasstr(vat(order, i));
    Value *b = vget(base.map, ref);
    Value *o = vget(over.map, ref);

    /* MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
     * (§9.3). A safety rule, not a tidiness one: if the overlay had its
     * defaults filled in before merging it would carry a synthesized
     * active:true and overwrite a base's false — silently re-enabling a
     * deliberately disabled integration in production. */
    Value *active = pick(o, "active", pick(b, "active", vbool(true)));
    Value *start = pick(o, "start", pick(b, "start", vstr("eager")));
    Value *ord = pick(o, "order", pick(b, "order", NULL));

    /* Option layers, levels 3-6, IN LADDER ORDER. Never merged here. */
    Value *layers = vlist();
    const char *nm = refname(ref);
    Value *bd = vget(basedef, nm);
    if (vismap(bd) && vhas(bd, "options")) vpush(layers, vget(bd, "options"));
    if (vismap(b) && vhas(b, "options")) vpush(layers, vget(b, "options"));
    Value *od = vget(overdef, nm);
    if (vismap(od) && vhas(od, "options")) vpush(layers, vget(od, "options"));
    if (vismap(o) && vhas(o, "options")) vpush(layers, vget(o, "options"));

    Value *ent = vmap();
    vset(ent, "pos", vnum((double)i));
    vset(ent, "active", active);
    vset(ent, "start", start);
    vset(ent, "optionlayers", layers);
    if (NULL != ord) vset(ent, "order", ord);
    vset(instance, ref, ent);
  }

  /* `default` DECLARES NOTHING (§9.3). It is a base for every instance
   * of that definition; it does not create one, and an entry for a name
   * with no instances is inert rather than an error — which is what
   * makes a shared library of defaults shippable. */
  Value *defout = vmap();
  size_t dn = vkeys(basedef, &rk);
  for (size_t i = 0; i < dn; i++) vset(defout, rk[i], vget(basedef, rk[i]));
  dn = vkeys(overdef, &rk);
  for (size_t i = 0; i < dn; i++) vset(defout, rk[i], vget(overdef, rk[i]));

  Value *out = vmap();
  vset(out, "instance", instance);
  vset(out, "order", order);
  vset(out, "default", defout);
  return out;
}

/* ------------------------------------------------------------------ */
/* resolveoptions — §9.3's ten levels, and §9.4's merge directives     */
/* ------------------------------------------------------------------ */

/* §9.4: N is an integer of at least 1, and everything else is an error.
 *
 * `{"deep": 0}` is rejected DESPITE having an obvious reading, because
 * "replace at this key" already has a spelling and two spellings for one
 * behaviour is the defect class this repo exists to avoid. Without the
 * stated domain each port picks its own reading — reject, replace,
 * unlimited merge, or clamp to 1 — and the same document resolves
 * differently per language. */
void checkshape(Value *shape) {
  if (!vismap(shape)) return;
  const char **keys;
  size_t n = vkeys(shape, &keys);
  for (size_t i = 0; i < n; i++) {
    Value *v = vget(shape, keys[i]);
    if (!vismap(v) || !vhas(v, "$MERGE")) continue;
    Value *d = vget(v, "$MERGE");

    if (visstr(d)) {
      const char *w = vasstr(d);
      if (0 == strcmp(w, "replace") || 0 == strcmp(w, "append")) continue;
      size_t sz = strlen(keys[i]) + strlen(w) + 64;
      char *text = (char *)arena_alloc(sz);
      snprintf(text, sz, "invalid $MERGE directive at %s: %s", keys[i], w);
      fail("plugin_shape_invalid", text,
           details2("key", vstr(keys[i]), "directive", d));
    }

    if (vismap(d) && vhas(d, "deep")) {
      Value *nv = vget(d, "deep");
      double x = vasnum(nv);
      if (!visnum(nv) || x != (double)(long long)x || 1 > x) {
        const char *shown = vjson(nv);
        size_t sz = strlen(keys[i]) + strlen(shown) + 64;
        char *text = (char *)arena_alloc(sz);
        snprintf(text, sz, "invalid $MERGE deep at %s: %s", keys[i], shown);
        fail("plugin_shape_invalid", text,
             details2("key", vstr(keys[i]), "directive", d));
      }
      continue;
    }

    const char *shown = vjson(d);
    size_t sz = strlen(keys[i]) + strlen(shown) + 64;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "invalid $MERGE directive at %s: %s", keys[i], shown);
    fail("plugin_shape_invalid", text,
         details2("key", vstr(keys[i]), "directive", d));
  }
}

/* The shape's non-directive values are the level-1 defaults. */
static Value *defaultsof(Value *shape) {
  Value *out = vmap();
  if (!vismap(shape)) return out;
  const char **keys;
  size_t n = vkeys(shape, &keys);
  for (size_t i = 0; i < n; i++) {
    Value *v = vget(shape, keys[i]);
    if (vismap(v) && vhas(v, "$MERGE")) continue;
    vset(out, keys[i], v);
  }
  return out;
}

static Value *optsof(Value *src, const char *key) {
  if (visnull(src)) return NULL;
  /* The array form is equivalent to the map form (§9.1). */
  if (vislist(src)) {
    for (size_t i = 0; i < vlen(src); i++) {
      Value *item = vat(src, i);
      if (0 == strcmp(canonref(vget(item, "ref")), key)) {
        return vhas(item, "options") ? vget(item, "options") : NULL;
      }
    }
    return NULL;
  }
  const char **keys;
  size_t n = vkeys(src, &keys);
  for (size_t i = 0; i < n; i++) {
    if (0 == strcmp(canonref(vstr(keys[i])), key)) {
      Value *e = vget(src, keys[i]);
      return vhas(e, "options") ? vget(e, "options") : NULL;
    }
  }
  return NULL;
}

/* Merge N levels below this key, replace below that. */
static Value *deepto(Value *base, Value *over, long n) {
  if (0 >= n) return vclone(over);
  if (!vismap(base) || !vismap(over)) return vclone(over);
  Value *out = vmap();
  const char **keys;
  size_t kn = vkeys(base, &keys);
  for (size_t i = 0; i < kn; i++) vset(out, keys[i], vget(base, keys[i]));
  kn = vkeys(over, &keys);
  for (size_t i = 0; i < kn; i++) {
    vset(out, keys[i], deepto(vget(out, keys[i]), vget(over, keys[i]), n - 1));
  }
  return out;
}

/* Merge ONE layer onto the accumulator, honouring the shape's
 * directives. The directive holds at EVERY precedence level, not only
 * between document levels — §9.4 makes it a property of the shape,
 * which does not know which layer a value arrived from. */
static Value *mergeone(Value *base, Value *over, Value *shape) {
  if (visnull(over)) return base;
  if (!vismap(base) || !vismap(over)) return vclone(over);

  Value *out = vmap();
  const char **keys;
  size_t n = vkeys(base, &keys);
  for (size_t i = 0; i < n; i++) vset(out, keys[i], vget(base, keys[i]));

  n = vkeys(over, &keys);
  for (size_t i = 0; i < n; i++) {
    const char *k = keys[i];
    Value *entry = vismap(shape) ? vget(shape, k) : NULL;
    Value *directive = vismap(entry) ? vget(entry, "$MERGE") : NULL;
    Value *b = vget(out, k);
    Value *o = vget(over, k);

    if (visstr(directive) && 0 == strcmp(vasstr(directive), "replace")) {
      vset(out, k, vclone(o));
    }
    else if (visstr(directive) && 0 == strcmp(vasstr(directive), "append")) {
      Value *merged = vlist();
      if (vislist(b)) {
        for (size_t j = 0; j < vlen(b); j++) vpush(merged, vat(b, j));
      }
      if (vislist(o)) {
        for (size_t j = 0; j < vlen(o); j++) vpush(merged, vat(o, j));
      }
      else {
        vpush(merged, o);
      }
      vset(out, k, merged);
    }
    else if (vismap(directive) && vhas(directive, "deep")) {
      vset(out, k, deepto(b, o, (long)vasnum(vget(directive, "deep"))));
    }
    else {
      /* Library default: deep for maps, REPLACE for lists. struct.merge
       * is element-wise by index, which for option maps is nearly always
       * wrong — ["a"] over ["x","y","z"] yielding ["a","y","z"] is the
       * defect station hit on secrets.providers. */
      if (vismap(b) && vismap(o)) vset(out, k, mergeone(b, o, NULL));
      else vset(out, k, vclone(o));
    }
  }
  return out;
}

Value *resolveoptions(Value *input) {
  Value *shape = vget(input, "shape");
  if (!vismap(shape)) shape = vmap();
  checkshape(shape);

  const char *ref = canonref(vget(input, "ref"));
  const char *name = refname(ref);
  Value *doc = vget(input, "doc");
  if (!vismap(doc)) doc = vmap();

  Value *profile = vget(input, "profile");
  Value *overlay = NULL;
  if (visstr(profile)) {
    overlay = vget(vget(doc, "profile"), vasstr(profile));
  }

  /* ONE ordered merge, lowest to highest. Levels 3-6 are not two
   * namespaces collapsed separately and composed afterwards: that
   * inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
   * SPECIFICITY, so a prod per-definition default would lose to a base
   * instance value. */
  Value *layers[10];
  layers[0] = defaultsof(shape);                                   /* 1 */
  layers[1] = vget(input, "hostdefaults");                         /* 2 */
  layers[2] = optsof(vget(doc, "default"), name);                  /* 3 */
  layers[3] = optsof(vget(doc, "instance"), ref);                  /* 4 */
  layers[4] = optsof(vismap(overlay) ? vget(overlay, "default") : NULL, name);   /* 5 */
  layers[5] = optsof(vismap(overlay) ? vget(overlay, "instance") : NULL, ref);   /* 6 */
  layers[6] = vget(input, "env");                                  /* 7 */
  layers[7] = vget(input, "hostoptions");                          /* 8 */
  layers[8] = vget(input, "loadoptions");                          /* 9 */
  layers[9] = vget(input, "patch");                                /* 10 */

  Value *out = vmap();
  for (int i = 0; i < 10; i++) {
    if (visnull(layers[i])) continue;
    out = mergeone(out, layers[i], shape);
  }
  return out;
}
