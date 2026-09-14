// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/ref.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Identity: name+tag (§4). */

#include "ref.hpp"

namespace plugin {

static const size_t MAX_REF = 1024;

static bool isnamehead(char c) {
  return ('a' <= c && 'z' >= c) || ('A' <= c && 'Z' >= c) || '@' == c;
}

static bool isnamebody(char c) {
  return ('a' <= c && 'z' >= c) || ('A' <= c && 'Z' >= c) ||
         ('0' <= c && '9' >= c) ||
         '.' == c || '~' == c || '_' == c || '-' == c || '/' == c;
}

static bool istagchar(char c) {
  return ('a' <= c && 'z' >= c) || ('A' <= c && 'Z' >= c) ||
         ('0' <= c && '9' >= c) ||
         '.' == c || '~' == c || '_' == c || '-' == c;
}

static bool namely(const std::string& name) {
  if (name.empty() || MAX_REF < name.size()) return false;
  if (!isnamehead(name[0])) return false;
  for (size_t i = 1; i < name.size(); i++) {
    if (!isnamebody(name[i])) return false;
  }
  return true;
}

static bool tagly(const std::string& tag) {
  /* The empty tag is an ordinary tag (§4 rule 2). The single-instance
   * case writes no tag and never learns tags exist. */
  if (tag.empty()) return true;
  if (MAX_REF < tag.size()) return false;
  for (char c : tag) {
    if (!istagchar(c)) return false;
  }
  return true;
}

bool checkname(const V& name) {
  /* A non-string is not a name. Every port has to answer this the same
   * way, and `ref/name` pins it for numbers, nulls and maps alike. */
  if (!isstr(name)) return false;
  return namely(asstr(name));
}

bool checktag(const V& tag) {
  if (!isstr(tag)) return false;
  return tagly(asstr(tag));
}

/* Split on the FIRST `$`. Nothing in the grammar decides this — `$` is
 * in neither character class — so the corpus is the arbiter (§4 rule
 * 5), and it picks the split that blames the part actually at fault:
 * `a$b$c` is a good name with a bad tag, not the reverse. */
static void split(const std::string& s, std::string& name, std::string& tag) {
  size_t cut = s.find('$');
  if (std::string::npos == cut) { name = s; tag = ""; return; }
  name = s.substr(0, cut);
  tag = s.substr(cut + 1);
}

V parseref(const V& str) {
  if (!isstr(str)) fail("plugin_bad_name", "ref must be a string");

  std::string name, tag;
  split(asstr(str), name, tag);

  if (!namely(name)) {
    fail("plugin_bad_name", "invalid plugin name: " + name,
         details1("name", vstr(name)));
  }
  if (!tagly(tag)) {
    fail("plugin_bad_tag", "invalid plugin tag: " + tag,
         details2("name", vstr(name), "tag", vstr(tag)));
  }

  V out = vmap();
  set(out, "name", vstr(name));
  set(out, "tag", vstr(tag));
  return out;
}

std::string formatref(const V& name, const V& tag) {
  bool tagok = isnull(tag) || isstr(tag);
  std::string t = isstr(tag) ? asstr(tag) : "";

  if (!checkname(name)) {
    std::string shown = isstr(name) ? asstr(name) : "";
    fail("plugin_bad_name", "invalid plugin name: " + shown,
         details1("name", isnull(name) ? vnull() : name));
  }
  if (!tagok || !tagly(t)) {
    fail("plugin_bad_tag", "invalid plugin tag: " + t,
         details2("name", name, "tag", isnull(tag) ? vstr("") : tag));
  }

  if (t.empty()) return asstr(name);
  return asstr(name) + "$" + t;
}

std::string canonref(const V& str) {
  V r = parseref(str);
  return formatref(get(r, "name"), get(r, "tag"));
}

std::string canonref(const std::string& str) { return canonref(vstr(str)); }

bool tryref(const std::string& str, std::string& out) {
  std::string name, tag;
  split(str, name, tag);
  if (!namely(name) || !tagly(tag)) return false;
  out = tag.empty() ? name : name + "$" + tag;
  return true;
}

std::string canon(const std::string& str) {
  std::string out;
  return tryref(str, out) ? out : str;
}

std::string refname(const std::string& str) {
  size_t cut = str.find('$');
  std::string name = (std::string::npos == cut) ? str : str.substr(0, cut);
  return namely(name) ? name : str;
}

}  // namespace plugin
