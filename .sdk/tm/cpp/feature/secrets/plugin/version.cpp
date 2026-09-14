// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/version.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Versions and ranges (§11.2). */

#include "version.hpp"

namespace plugin {

/* A COMPONENT IS BOUNDED, like a ref is (§4's 1024).
 *
 * The grammar admits an unbounded digit sequence, and every language
 * then disagrees about what happens past its integer range: JavaScript
 * silently loses precision, Go's Atoi errors (and a port ignoring that
 * gets 0), C overflows, Python is exact. `satisfies("0",
 * "9223372036854775808")` was false in the canonical and true in go,
 * from the same corpus.
 *
 * 2^31-1 because every port has a signed 32-bit integer, and no real
 * version has ever needed more. Stated rather than left to arithmetic
 * nobody agrees on. Found by review of the go port. */
static const long COMPONENT_MAX = 2147483647L;

/* `^(\d+)(?:\.(\d+))?(?:\.(\d+))?$`, by hand: three components, digits
 * only, no leading sign, no empty component. Written out rather than
 * handed to <regex> because the bound below has to be checked per
 * component anyway, and a regex that matched then needed re-scanning
 * would be the worse of both. */
static bool parse3(const std::string& s, long out[3], bool& overflow) {
  out[0] = out[1] = out[2] = 0;
  overflow = false;
  if (s.empty()) return false;

  size_t i = 0;
  for (int part = 0; part < 3; part++) {
    if (i >= s.size()) return 0 < part;   /* fewer than three is fine */
    if (0 < part) {
      if ('.' != s[i]) return false;
      i++;
    }
    size_t start = i;
    long acc = 0;
    while (i < s.size() && '0' <= s[i] && '9' >= s[i]) {
      if (!overflow) {
        acc = acc * 10 + (s[i] - '0');
        if (COMPONENT_MAX < acc) overflow = true;
      }
      i++;
    }
    if (start == i) return false;   /* an empty component is not a number */
    out[part] = acc;
  }
  return i == s.size();
}

static V triple(const long n[3]) {
  V out = vlist();
  for (int i = 0; i < 3; i++) push(out, vnum(static_cast<double>(n[i])));
  return out;
}

V parserange(const V& range) {
  if (!isstr(range) || asstr(range).empty()) {
    std::string shown = isstr(range) ? asstr(range) : "";
    fail("plugin_bad_range", "invalid range: " + shown,
         details1("range", isnull(range) ? vnull() : range));
  }

  const std::string s = asstr(range);
  /* Two forms and no more (§11.2):
   *   '2.1'   >= 2.1.0 and < 3.0.0
   *   '~2.1'  >= 2.1.0 and < 2.2.0 */
  bool tilde = '~' == s[0];
  std::string body = tilde ? s.substr(1) : s;

  long n[3];
  bool overflow = false;
  if (!parse3(body, n, overflow) || overflow) {
    fail("plugin_bad_range",
         overflow ? "version component out of range in " + s
                  : "invalid range: " + s,
         details1("range", range));
  }

  long lo[3] = { n[0], n[1], n[2] };
  long hi[3];
  if (tilde) { hi[0] = n[0]; hi[1] = n[1] + 1; hi[2] = 0; }
  else { hi[0] = n[0] + 1; hi[1] = 0; hi[2] = 0; }

  V out = vmap();
  set(out, "lo", triple(lo));
  set(out, "hi", triple(hi));
  return out;
}

V parseversion(const V& version) {
  if (!isstr(version)) {
    fail("plugin_bad_range", "invalid version",
         details1("version", isnull(version) ? vnull() : version));
  }
  const std::string s = asstr(version);
  long n[3];
  bool overflow = false;
  if (!parse3(s, n, overflow) || overflow) {
    /* `plugin_bad_range` either way — the same code the rest of the
     * grammar's failures use, because "this is not a version I can
     * compare" is one fact however it went wrong. */
    fail("plugin_bad_range",
         overflow ? "version component out of range in " + s
                  : "invalid version: " + s,
         details1("version", version));
  }
  return triple(n);
}

int vercmp(const V& a, const V& b) {
  for (size_t i = 0; i < 3; i++) {
    double x = asnum(at(a, i));
    double y = asnum(at(b, i));
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

bool satisfies(const V& version, const V& range) {
  V v = parseversion(version);
  V r = parserange(range);
  return 0 <= vercmp(v, get(r, "lo")) && 0 > vercmp(v, get(r, "hi"));
}

bool satisfiesq(const V& version, const V& range) {
  /* `satisfies` for the internal callers that treat an unparseable
   * version or range as "does not satisfy" — Capability and Graph, both
   * of which run over data the corpus has already admitted. */
  try {
    return satisfies(version, range);
  }
  catch (const PluginError&) {
    return false;
  }
}

}  // namespace plugin
