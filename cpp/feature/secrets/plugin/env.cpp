// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/env.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Environment overrides (§9.5) — level 7 of the ladder.
 *
 * One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
 *
 *   VOXGIG_PLUGIN_PROFILE            the profile name
 *   VOXGIG_PLUGIN_<REF>_<PATH>       one option
 *   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
 *
 * THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
 * OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` ->
 * `_`. But `_` is legal in a name and in a tag, and the mapping folds
 * case, so `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.
 *
 * Rather than restrict a grammar the rest of the stack already uses,
 * the host DETECTS THE COLLISION: it encodes every ref it holds, and a
 * key two refs claim is `plugin_env_ambiguous`, naming both. */

#include "env.hpp"

#include <algorithm>

#include "ref.hpp"

namespace plugin {

static const char* const PREFIX = "VOXGIG_PLUGIN_";

std::string encoderef(const std::string& ref) {
  std::string out;
  out.reserve(ref.size() * 2);
  for (char c : ref) {
    if ('$' == c) out += "__";
    else if ('.' == c) out += '_';
    else if ('a' <= c && 'z' >= c) out += static_cast<char>(c - 'a' + 'A');
    else out += c;
  }
  return out;
}

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

/* Values parse as JSON, FALLING BACK TO STRING — so `8080` is a number,
 * `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
 * looks like rather than a parse error. */
static V parsevalue(const std::string& v) {
  std::string err;
  V parsed = parsejson(v, err);
  return parsed ? parsed : vstr(v);
}

static std::string lower(std::string s) {
  for (char& c : s) {
    if ('A' <= c && 'Z' >= c) c = static_cast<char>(c - 'A' + 'a');
  }
  return s;
}

V applyenv(const V& input) {
  V env = get(input, "env");
  if (!ismap(env)) env = vmap();
  V refsin = get(input, "refs");
  V reserved = get(input, "reserved");

  V out = vmap();
  V options = vmap();
  V active = vlist();
  V inactive = vlist();
  set(out, "options", options);
  set(out, "active", active);
  set(out, "inactive", inactive);

  /* Encode every ref the host holds, and refuse a key that two of them
   * claim. Done UP FRONT so the collision is reported even when no
   * environment variable exercises it — a latent ambiguity is still an
   * ambiguity, and finding it at deploy time is the failure this exists
   * to prevent. */
  V byencoded = vmap();
  if (islist(refsin)) {
    for (size_t i = 0; i < len(refsin); i++) {
      const std::string r = canonref(at(refsin, i));
      const std::string e = encoderef(r);
      V list = get(byencoded, e);
      if (isnull(list)) { list = vlist(); set(byencoded, e, list); }
      push(list, vstr(r));
    }
  }

  auto encs = sortedkeys(byencoded);
  for (const auto& e : encs) {
    V claims = get(byencoded, e);
    if (1 < len(claims)) {
      std::string a = asstr(at(claims, 0));
      std::string b = asstr(at(claims, 1));
      const std::string& lo = a <= b ? a : b;
      const std::string& hi = a <= b ? b : a;
      V pair = vlist();
      push(pair, vstr(lo));
      push(pair, vstr(hi));
      V d = vmap();
      set(d, "encoded", vstr(e));
      set(d, "refs", pair);
      fail("plugin_env_ambiguous",
           "refs collide in the environment encoding as " + e + ": " + lo +
               ", " + hi,
           d);
    }
  }

  /* LONGEST encoded ref first, so `retry$fast` wins over `retry` on
   * `RETRY__FAST_MIN`. Shortest-first would read the tag as a path. */
  auto order = encs;
  std::sort(order.begin(), order.end(),
            [](const std::string& a, const std::string& b) {
              if (a.size() != b.size()) return a.size() > b.size();
              return a < b;
            });

  const size_t plen = std::string(PREFIX).size();

  for (const auto& key : sortedkeys(env)) {
    if (0 != key.compare(0, plen, PREFIX)) continue;
    const std::string rest = key.substr(plen);
    const std::string val = asstr(get(env, key));

    if ("PROFILE" == rest) {
      set(out, "profile", vstr(val));
      continue;
    }

    if ("ACTIVE" == rest || "INACTIVE" == rest) {
      bool isactive = "ACTIVE" == rest;
      size_t p = 0;
      while (p <= val.size()) {
        size_t comma = val.find(',', p);
        size_t end = (std::string::npos == comma) ? val.size() : comma;
        size_t s = p;
        while (s < end && (' ' == val[s] || '\t' == val[s])) s++;
        size_t e = end;
        while (e > s && (' ' == val[e - 1] || '\t' == val[e - 1])) e--;
        if (e > s) {
          const std::string c = canonref(vstr(val.substr(s, e - s)));
          /* The reservation covers EVERY input layer (§9.1).
           * VOXGIG_PLUGIN_INACTIVE=station is easier to set than
           * editing a config file, and INACTIVE has the final word — so
           * guarding documents alone would leave the one lever this
           * mechanism exists to deny wide open. */
          checkreserved(c, reserved);
          push(isactive ? active : inactive, vstr(c));
        }
        if (std::string::npos == comma) break;
        p = comma + 1;
      }
      continue;
    }

    std::string enc;
    bool found = false;
    for (const auto& cand : order) {
      if (rest == cand ||
          (rest.size() > cand.size() &&
           0 == rest.compare(0, cand.size(), cand) && '_' == rest[cand.size()])) {
        enc = cand;
        found = true;
        break;
      }
    }
    if (!found) continue;   /* not for any ref this host holds */

    const std::string ref = asstr(at(get(byencoded, enc), 0));
    checkreserved(ref, reserved);

    if (rest == enc) continue;   /* a ref with no path sets nothing */

    std::string pathtext = rest.substr(enc.size() + 1);
    V node = get(options, ref);
    if (isnull(node)) { node = vmap(); set(options, ref, node); }

    for (;;) {
      size_t dot = pathtext.find('_');
      if (std::string::npos == dot) break;
      const std::string piece = lower(pathtext.substr(0, dot));
      V next = get(node, piece);
      if (!ismap(next)) { next = vmap(); set(node, piece, next); }
      node = next;
      pathtext = pathtext.substr(dot + 1);
    }
    set(node, lower(pathtext), parsevalue(val));
  }

  return out;
}

}  // namespace plugin
