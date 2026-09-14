// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/value.hpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The dynamic value, and the JSON reader that fills it (§16).
 *
 * NO DEPENDENCIES, not even a JSON library: §16 permits exactly one
 * runtime dependency (voxgig/struct) and C++ has no port of it, so the
 * corpus JSON is parsed here. A package graph is also a supply chain.
 *
 * SHARED_PTR, NOT AN ARENA — and that is the whole difference from the
 * `c` port sitting next door. C++ has destructors and shared ownership,
 * so a value's lifetime is the language's problem rather than the
 * library's, and the arena that makes `longjmp` safe in c is not needed
 * where `throw` unwinds properly.
 *
 * NULLPTR MEANS "NOTHING", A NULL VALUE MEANS "JSON null". They are
 * different answers and several places need both: `bail` declining is
 * not `bail` answering null, and a missing export is not an export of
 * null. Every accessor here tolerates a nullptr, which is why they are
 * free functions rather than members.
 *
 * A MAP PRESERVES INSERTION ORDER AND SORTS ON DEMAND. §4 rule 4 makes
 * order observable in several places (`keys` is sorted, `pos` is the
 * sorted-ref index), so both orders have to be available and the code
 * has to say which it means at each use. */

#ifndef VOXGIG_PLUGIN_VALUE_HPP
#define VOXGIG_PLUGIN_VALUE_HPP

#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace plugin {

enum class Kind { Null, Bool, Num, Str, List, Map };

class Value;
using V = std::shared_ptr<Value>;

class Value {
 public:
  Kind kind = Kind::Null;
  bool boolean = false;
  double num = 0;
  std::string str;
  std::vector<V> items;
  /* A vector of pairs rather than a std::map: insertion order must
   * survive, the maps here hold a handful of keys, and an ordered
   * container keyed by string would sort them behind our back. */
  std::vector<std::pair<std::string, V>> entries;
};

/* --- construction --------------------------------------------------- */

V vnull();
V vbool(bool b);
V vnum(double n);
V vstr(const std::string& s);
V vlist();
V vmap();

/* --- kinds ---------------------------------------------------------- */

bool isnull(const V& v);
bool isbool(const V& v);
bool isnum(const V& v);
bool isstr(const V& v);
bool islist(const V& v);
bool ismap(const V& v);

/* --- access --------------------------------------------------------- */

/* `get` answers a null Value for a missing key AND for a key holding
 * JSON null; `has` distinguishes them, which is what §9.1's "an
 * authored null is not an absent key" needs. */
V get(const V& m, const std::string& key);
bool has(const V& m, const std::string& key);
void set(const V& m, const std::string& key, const V& val);
void del(const V& m, const std::string& key);

V at(const V& l, size_t i);
void push(const V& l, const V& item);
size_t len(const V& v);

std::string asstr(const V& v);
double asnum(const V& v);
bool asbool(const V& v);

/* Keys in INSERTION order. */
std::vector<std::string> keys(const V& m);
/* Keys SORTED by byte order — §4 rule 4's deterministic walk. */
std::vector<std::string> sortedkeys(const V& m);

/* §4 rule 4: truthiness is JSON's, not C++'s. */
bool truthy(const V& v);

/* Deep equality INCLUDING JSON type, which is the half that matters:
 * half the ports are written in languages whose `==` says `true == 1`,
 * and `capability/match` exists to catch exactly that. */
bool same(const V& a, const V& b);

V clone(const V& v);

/* --- json ----------------------------------------------------------- */

/* Parse, or nullptr with `err` set to a message. */
V parsejson(const std::string& text, std::string& err);
/* Canonical JSON, keys in SORTED order so two values that are `same`
 * render identically — the corpus compares rendered forms in places. */
std::string json(const V& v);

/* Numbers render as integers when they are integral, which is what the
 * corpus's expected values look like. */
std::string numstr(double n);

}  // namespace plugin

#endif
