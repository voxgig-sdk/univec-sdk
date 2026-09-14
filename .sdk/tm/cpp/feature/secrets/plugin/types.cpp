// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/types.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Errors and the raise mechanism. See types.hpp for why exceptions. */

#include "types.hpp"

namespace plugin {

/* §12's detail fields, IN THIS FIXED ORDER. The order is part of the
 * contract: an earlier draft named six fields while other sections
 * promised diagnostics with nowhere to go, which would have left each
 * port inventing its own order and breaking message parity. */
static const char* const DETAIL_ORDER[] = {
  "host", "ref", "name", "tag", "point", "key", "capability",
  "range", "version", "match", "candidates", "cycle", "holders",
  "refs", "path", "cause", nullptr
};

std::string formaterror(const std::string& code, const std::string& text,
                        const V& details) {
  /* Values render as COMPACT JSON, so a value containing a space or a
   * bracket cannot break the parse and a list renders as an array. The
   * bracket is absent entirely when no field applies. */
  std::string tail;
  for (int i = 0; nullptr != DETAIL_ORDER[i]; i++) {
    const std::string k = DETAIL_ORDER[i];
    if (!has(details, k)) continue;
    if (!tail.empty()) tail += ' ';
    tail += k;
    tail += '=';
    tail += json(get(details, k));
  }

  std::string out = "plugin/" + code + ": " + text;
  if (!tail.empty()) out += " [" + tail + "]";
  return out;
}

PluginError::PluginError(std::string c, std::string t, V d)
    : code(std::move(c)),
      text(std::move(t)),
      details(d ? d : vmap()),
      message(formaterror(code, text, details)) {}

void fail(const std::string& code, const std::string& text, const V& details) {
  throw PluginError(code, text, details);
}

V details1(const std::string& k, const V& v) {
  V d = vmap();
  set(d, k, v);
  return d;
}

V details2(const std::string& k1, const V& v1, const std::string& k2,
           const V& v2) {
  V d = vmap();
  set(d, k1, v1);
  set(d, k2, v2);
  return d;
}

V mergevalue(const V& a, const V& b) {
  if (!ismap(a) || !ismap(b)) return b ? b : a;
  V out = vmap();
  for (const auto& k : keys(a)) set(out, k, get(a, k));
  for (const auto& k : keys(b)) {
    V bv = get(b, k);
    V av = get(out, k);
    if (ismap(av) && ismap(bv)) set(out, k, mergevalue(av, bv));
    else set(out, k, bv);
  }
  return out;
}

bool matchvalue(const V& want, const V& have) {
  if (isnull(want)) return true;
  if (ismap(want)) {
    if (!ismap(have)) return false;
    for (const auto& k : keys(want)) {
      if (!has(have, k)) return false;
      if (!matchvalue(get(want, k), get(have, k))) return false;
    }
    return true;
  }
  return same(want, have);
}

}  // namespace plugin
