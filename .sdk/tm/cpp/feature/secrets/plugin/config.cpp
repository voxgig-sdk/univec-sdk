// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/config.cpp)
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

#include "config.hpp"

#include <algorithm>

#include "ref.hpp"

namespace plugin {

/* §9.1: reservation is all-or-nothing per NAME, so the tagged forms go
 * too. A configuration surface that can disable the thing reading it is
 * not a surface, it is a trap. */
static void checkreserved(const std::string& ref, const V& reserved) {
  if (!islist(reserved) || 0 == len(reserved)) return;
  const std::string name = refname(ref);
  for (size_t i = 0; i < len(reserved); i++) {
    if (isstr(at(reserved, i)) && asstr(at(reserved, i)) == name) {
      fail("plugin_ref_reserved", "ref is reserved by the host: " + ref,
           details1("ref", vstr(ref)));
    }
  }
}

/* Both document forms reduce to {ref -> entry} plus the order the form
 * implies: array POSITION for the array form, sorted refs for the map
 * form. */
struct Entries {
  V map = vmap();
  V order = vlist();
};

static Entries entriesof(const V& src) {
  Entries out;
  if (isnull(src)) return out;

  if (islist(src)) {
    for (size_t i = 0; i < len(src); i++) {
      V item = at(src, i);
      const std::string ref = canonref(get(item, "ref"));
      set(out.map, ref, item);
      push(out.order, vstr(ref));
    }
    return out;
  }

  /* Map-form refs arrive as KEYS, through a different path than an
   * array element's `ref` field — and must canonicalize the same way. */
  for (const auto& k : keys(src)) {
    set(out.map, canonref(vstr(k)), get(src, k));
  }
  /* Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
   * sort identically under all three, so only mixed input
   * discriminates: '@' is 0x40, uppercase 0x41-0x5A, lowercase
   * 0x61-0x7A. */
  for (const auto& k : sortedkeys(out.map)) push(out.order, vstr(k));
  return out;
}

/* PRESENT WINS, EVEN WHEN THE VALUE IS NULL. The canonical is
 * `src && undefined !== src[key]`, and in JavaScript a key holding
 * `null` passes that test — so a profile's `order: null` clears a base
 * ordering block and `active: null` over a base `active: true` is
 * falsy, and barred. Testing for non-null instead treated an authored
 * null as an absent key, which is §9.1's distinction inverted. */
static V pick(const V& src, const std::string& key, const V& dflt) {
  if (ismap(src) && has(src, key)) return get(src, key);
  return dflt;
}

static bool listhas(const V& list, const std::string& s) {
  for (size_t i = 0; i < len(list); i++) {
    if (isstr(at(list, i)) && asstr(at(list, i)) == s) return true;
  }
  return false;
}

V normalizeconfig(const V& input) {
  V doc = get(input, "doc");
  if (!ismap(doc)) doc = vmap();
  V keyspec = get(input, "keys");
  const std::string ikey =
      isstr(get(keyspec, "instance")) ? asstr(get(keyspec, "instance")) : "instance";
  const std::string dkey =
      isstr(get(keyspec, "default")) ? asstr(get(keyspec, "default")) : "default";
  V reserved = get(input, "reserved");
  V profile = get(input, "profile");

  /* The rename is applied at TWO PLACES AND NO OTHERS: the document
   * root, and every profile.<name> overlay root (§9.1). A rename applied
   * only at the root would leave `profile.prod.sdk` untranslated and
   * silently drop every environment override the host depends on.
   * Recursing further would be worse: option data is the definition's. */
  V baseinst = get(doc, ikey);
  V basedef = get(doc, dkey);
  if (!ismap(basedef)) basedef = vmap();

  V overlay = nullptr;
  if (isstr(profile)) {
    overlay = get(get(doc, "profile"), asstr(profile));
  }
  V overinst = ismap(overlay) ? get(overlay, ikey) : nullptr;
  V overdef = ismap(overlay) ? get(overlay, dkey) : nullptr;
  if (!ismap(overdef)) overdef = vmap();

  Entries base = entriesof(baseinst);
  Entries over = entriesof(overinst);

  for (const auto& k : keys(base.map)) checkreserved(k, reserved);
  for (const auto& k : keys(over.map)) checkreserved(k, reserved);
  for (const auto& k : keys(basedef)) checkreserved(k, reserved);
  for (const auto& k : keys(overdef)) checkreserved(k, reserved);

  /* A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the hard
   * way: deriving order from a partial array silently dropped
   * config-activated features. Refs in the base but absent from the
   * overlay still load, in sorted position AFTER the listed ones. A
   * profile may also INTRODUCE a ref the base never declared. */
  V order = vlist();
  for (size_t i = 0; i < len(over.order); i++) {
    const std::string r = asstr(at(over.order, i));
    if (!listhas(order, r)) push(order, vstr(r));
  }
  /* The remainder keeps the BASE's own order — array position for the
   * array form, sorted refs for the map form. Re-sorting here would
   * discard an array document's positional order entirely, which is the
   * one thing the array form exists to express. */
  for (size_t i = 0; i < len(base.order); i++) {
    const std::string r = asstr(at(base.order, i));
    if (!listhas(order, r)) push(order, vstr(r));
  }

  V instance = vmap();
  for (size_t i = 0; i < len(order); i++) {
    const std::string ref = asstr(at(order, i));
    V b = get(base.map, ref);
    V o = get(over.map, ref);

    /* MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
     * (§9.3). A safety rule, not a tidiness one: if the overlay had its
     * defaults filled in before merging it would carry a synthesized
     * active:true and overwrite a base's false — silently re-enabling a
     * deliberately disabled integration in production. */
    V active = pick(o, "active", pick(b, "active", vbool(true)));
    V start = pick(o, "start", pick(b, "start", vstr("eager")));
    V ord = pick(o, "order", pick(b, "order", nullptr));

    /* Option layers, levels 3-6, IN LADDER ORDER. Never merged here. */
    V layers = vlist();
    const std::string nm = refname(ref);
    V bd = get(basedef, nm);
    if (ismap(bd) && has(bd, "options")) push(layers, get(bd, "options"));
    if (ismap(b) && has(b, "options")) push(layers, get(b, "options"));
    V od = get(overdef, nm);
    if (ismap(od) && has(od, "options")) push(layers, get(od, "options"));
    if (ismap(o) && has(o, "options")) push(layers, get(o, "options"));

    V ent = vmap();
    set(ent, "pos", vnum(static_cast<double>(i)));
    set(ent, "active", active);
    set(ent, "start", start);
    set(ent, "optionlayers", layers);
    if (ord) set(ent, "order", ord);
    set(instance, ref, ent);
  }

  /* `default` DECLARES NOTHING (§9.3). It is a base for every instance
   * of that definition; it does not create one, and an entry for a name
   * with no instances is inert rather than an error — which is what
   * makes a shared library of defaults shippable. */
  V defout = vmap();
  for (const auto& k : keys(basedef)) set(defout, k, get(basedef, k));
  for (const auto& k : keys(overdef)) set(defout, k, get(overdef, k));

  V out = vmap();
  set(out, "instance", instance);
  set(out, "order", order);
  set(out, "default", defout);
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
void checkshape(const V& shape) {
  if (!ismap(shape)) return;
  for (const auto& k : keys(shape)) {
    V v = get(shape, k);
    if (!ismap(v) || !has(v, "$MERGE")) continue;
    V d = get(v, "$MERGE");

    if (isstr(d)) {
      const std::string w = asstr(d);
      if ("replace" == w || "append" == w) continue;
      fail("plugin_shape_invalid", "invalid $MERGE directive at " + k + ": " + w,
           details2("key", vstr(k), "directive", d));
    }

    if (ismap(d) && has(d, "deep")) {
      V nv = get(d, "deep");
      double x = asnum(nv);
      if (!isnum(nv) || x != static_cast<double>(static_cast<long long>(x)) ||
          1 > x) {
        fail("plugin_shape_invalid",
             "invalid $MERGE deep at " + k + ": " + json(nv),
             details2("key", vstr(k), "directive", d));
      }
      continue;
    }

    fail("plugin_shape_invalid",
         "invalid $MERGE directive at " + k + ": " + json(d),
         details2("key", vstr(k), "directive", d));
  }
}

/* The shape's non-directive values are the level-1 defaults. */
static V defaultsof(const V& shape) {
  V out = vmap();
  if (!ismap(shape)) return out;
  for (const auto& k : keys(shape)) {
    V v = get(shape, k);
    if (ismap(v) && has(v, "$MERGE")) continue;
    set(out, k, v);
  }
  return out;
}

static V optsof(const V& src, const std::string& key) {
  if (isnull(src)) return nullptr;
  /* The array form is equivalent to the map form (§9.1). */
  if (islist(src)) {
    for (size_t i = 0; i < len(src); i++) {
      V item = at(src, i);
      if (canonref(get(item, "ref")) == key) {
        return has(item, "options") ? get(item, "options") : nullptr;
      }
    }
    return nullptr;
  }
  for (const auto& k : keys(src)) {
    if (canonref(vstr(k)) == key) {
      V e = get(src, k);
      return has(e, "options") ? get(e, "options") : nullptr;
    }
  }
  return nullptr;
}

/* Merge N levels below this key, replace below that. */
static V deepto(const V& base, const V& over, long n) {
  if (0 >= n) return clone(over);
  if (!ismap(base) || !ismap(over)) return clone(over);
  V out = vmap();
  for (const auto& k : keys(base)) set(out, k, get(base, k));
  for (const auto& k : keys(over)) {
    set(out, k, deepto(get(out, k), get(over, k), n - 1));
  }
  return out;
}

/* Merge ONE layer onto the accumulator, honouring the shape's
 * directives. The directive holds at EVERY precedence level, not only
 * between document levels — §9.4 makes it a property of the shape,
 * which does not know which layer a value arrived from. */
static V mergeone(const V& base, const V& over, const V& shape) {
  if (isnull(over)) return base;
  if (!ismap(base) || !ismap(over)) return clone(over);

  V out = vmap();
  for (const auto& k : keys(base)) set(out, k, get(base, k));

  for (const auto& k : keys(over)) {
    V entry = ismap(shape) ? get(shape, k) : nullptr;
    V directive = ismap(entry) ? get(entry, "$MERGE") : nullptr;
    V b = get(out, k);
    V o = get(over, k);

    if (isstr(directive) && "replace" == asstr(directive)) {
      set(out, k, clone(o));
    }
    else if (isstr(directive) && "append" == asstr(directive)) {
      V merged = vlist();
      if (islist(b)) {
        for (size_t j = 0; j < len(b); j++) push(merged, at(b, j));
      }
      if (islist(o)) {
        for (size_t j = 0; j < len(o); j++) push(merged, at(o, j));
      }
      else {
        push(merged, o);
      }
      set(out, k, merged);
    }
    else if (ismap(directive) && has(directive, "deep")) {
      set(out, k,
          deepto(b, o, static_cast<long>(asnum(get(directive, "deep")))));
    }
    else {
      /* Library default: deep for maps, REPLACE for lists. struct.merge
       * is element-wise by index, which for option maps is nearly always
       * wrong — ["a"] over ["x","y","z"] yielding ["a","y","z"] is the
       * defect station hit on secrets.providers. */
      if (ismap(b) && ismap(o)) set(out, k, mergeone(b, o, nullptr));
      else set(out, k, clone(o));
    }
  }
  return out;
}

V resolveoptions(const V& input) {
  V shape = get(input, "shape");
  if (!ismap(shape)) shape = vmap();
  checkshape(shape);

  const std::string ref = canonref(get(input, "ref"));
  const std::string name = refname(ref);
  V doc = get(input, "doc");
  if (!ismap(doc)) doc = vmap();

  V profile = get(input, "profile");
  V overlay = nullptr;
  if (isstr(profile)) overlay = get(get(doc, "profile"), asstr(profile));

  /* ONE ordered merge, lowest to highest. Levels 3-6 are not two
   * namespaces collapsed separately and composed afterwards: that
   * inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
   * SPECIFICITY, so a prod per-definition default would lose to a base
   * instance value. */
  const V layers[10] = {
    defaultsof(shape),                                                 /* 1 */
    get(input, "hostdefaults"),                                        /* 2 */
    optsof(get(doc, "default"), name),                                 /* 3 */
    optsof(get(doc, "instance"), ref),                                 /* 4 */
    optsof(ismap(overlay) ? get(overlay, "default") : nullptr, name),  /* 5 */
    optsof(ismap(overlay) ? get(overlay, "instance") : nullptr, ref),  /* 6 */
    get(input, "env"),                                                 /* 7 */
    get(input, "hostoptions"),                                         /* 8 */
    get(input, "loadoptions"),                                         /* 9 */
    get(input, "patch"),                                               /* 10 */
  };

  V out = vmap();
  for (const auto& layer : layers) {
    if (isnull(layer)) continue;
    out = mergeone(out, layer, shape);
  }
  return out;
}

}  // namespace plugin
