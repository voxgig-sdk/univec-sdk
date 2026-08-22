// Univec SDK — struct facade + shared helpers.
//
// The generated SDK's data model IS the vendored voxgig struct Value
// (utility/voxgigstruct). This header exposes the struct utility functions
// through the `Struct` facade (java-style call sites) plus a set of short
// Value helpers used throughout the pipeline, features and tests. Maps and
// lists are reference-stable (shared_ptr) so mutation propagates to every
// alias — the property merge/walk/inject and the SDK pipeline rely on.

#ifndef SDK_CORE_STRUCT_HPP
#define SDK_CORE_STRUCT_HPP

#include <functional>
#include <initializer_list>
#include <string>
#include <utility>
#include <vector>

#include "../utility/voxgigstruct/voxgig_struct.hpp"
#include "../utility/voxgigstruct/value_io.hpp"

namespace sdk {

namespace vs = voxgig::structlib;

using Value = vs::Value;
using List = vs::List;
using Map = vs::Map;

// ---- constructors -----------------------------------------------------

inline Value vmap() { return Value::map(); }

inline Value vmap(std::initializer_list<std::pair<std::string, Value>> il) {
  Value m = Value::map();
  auto mm = m.as_map();
  for (const auto& kv : il) {
    mm->set(kv.first, kv.second);
  }
  return m;
}

inline Value vlist() { return Value(std::make_shared<List>()); }

inline Value vlist(std::initializer_list<Value> il) {
  auto l = std::make_shared<List>(il.begin(), il.end());
  return Value(std::move(l));
}

// ---- predicates -------------------------------------------------------

inline bool is_map(const Value& v) { return v.is_map(); }
inline bool is_list(const Value& v) { return v.is_list(); }
inline bool is_str(const Value& v) { return v.is_string(); }
inline bool is_num(const Value& v) { return v.is_number(); }
inline bool is_bool(const Value& v) { return v.is_bool(); }
inline bool is_undef(const Value& v) { return v.is_undef(); }
inline bool is_null(const Value& v) { return v.is_null(); }
inline bool is_func(const Value& v) { return v.is_func(); }
inline bool is_nullish(const Value& v) { return v.is_undef() || v.is_null(); }

// ---- scalar extraction ------------------------------------------------

inline std::string as_str(const Value& v, const std::string& def = "") {
  return v.is_string() ? v.as_string() : def;
}
inline int as_int(const Value& v, int def = -1) {
  return v.is_number() ? static_cast<int>(v.as_int()) : def;
}
inline long long as_long(const Value& v, long long def = 0) {
  return v.is_number() ? static_cast<long long>(v.as_int()) : def;
}
inline double as_num(const Value& v, double def = 0.0) {
  return v.is_number() ? v.as_double() : def;
}
inline bool as_bool(const Value& v, bool def = false) {
  return v.is_bool() ? v.as_bool() : def;
}

// java Boolean.TRUE.equals(x)
inline bool is_true(const Value& v) { return v.is_bool() && v.as_bool(); }
inline bool is_false(const Value& v) { return v.is_bool() && !v.as_bool(); }

// ---- map / list access ------------------------------------------------

// getprop: Group A read (stored-null treated as absent -> undef). The
// Value-key overload accepts string literals, std::string and Value keys
// uniformly (single implicit conversion) — avoiding literal ambiguity.
inline Value getp(const Value& v, const Value& key) { return vs::getprop(v, key); }
inline Value getp(const Value& v, const Value& key, const Value& alt) {
  return vs::getprop(v, key, alt);
}

// setprop: mutate the (shared) map/list in place; returns the same root node.
inline Value setp(const Value& parent, const Value& key, const Value& val) {
  return vs::setprop(parent, key, val);
}

// map raw get (null-preserving) — java map.get() for present-null.
inline Value mapget(const Value& v, const std::string& key) {
  return vs::lookup_v(v, Value(key));
}

// containsKey (exact — a stored null counts as present).
inline bool map_contains(const Value& v, const std::string& key) {
  return v.is_map() && v.as_map()->contains(key);
}

inline void map_put(const Value& v, const std::string& key, const Value& val) {
  if (v.is_map()) v.as_map()->set(key, val);
}

inline void map_remove(const Value& v, const std::string& key) {
  if (v.is_map()) v.as_map()->erase(key);
}

// haskey: Group A.
inline bool has_key(const Value& v, const Value& key) { return vs::haskey(v, key); }

// toMapAny: return v if it is a map, else undef.
inline Value to_map(const Value& v) { return v.is_map() ? v : Value::undef(); }

// pair helpers for Struct.items() iteration.
inline Value pair_key(const Value& item) { return vs::getelem(item, Value(int64_t(0))); }
inline Value pair_val(const Value& item) { return vs::getelem(item, Value(int64_t(1))); }

// json_thunk: a transport "json" callable yielding a fixed body (the struct
// Injector convention used by the mock transport and generated tests).
inline Value json_thunk(const Value& data) {
  vs::Injector fn = [data](vs::Injection&, const Value&, const std::string&, const Value&) -> Value {
    return data;
  };
  return Value(fn);
}

// ---- Struct facade (java Struct.X call sites) -------------------------

namespace Struct {

inline const Value UNDEF = Value::undef();

constexpr int T_string = vs::T_string;
constexpr int T_number = vs::T_number;

inline Value getprop(const Value& v, const Value& key) { return vs::getprop(v, key); }
inline Value getprop(const Value& v, const Value& key, const Value& alt) {
  return vs::getprop(v, key, alt);
}
inline Value getelem(const Value& v, const Value& key) { return vs::getelem(v, key); }
inline Value getelem(const Value& v, int index) {
  return vs::getelem(v, Value(static_cast<int64_t>(index)));
}
inline Value delprop(const Value& parent, const Value& key) { return vs::delprop(parent, key); }

// walk callback: (key, val, parent, path) -> replacement value.
using WalkFn = std::function<Value(const Value&, const Value&, const Value&,
                                   const std::vector<std::string>&)>;
inline Value walk(const Value& v, const WalkFn& before) { return vs::walk_v(v, before); }

inline Value setprop(const Value& parent, const Value& key, const Value& val) {
  return vs::setprop(parent, key, val);
}

inline bool haskey(const Value& v, const Value& key) { return vs::haskey(v, key); }
inline bool isnode(const Value& v) { return vs::isnode(v); }
inline bool ismap(const Value& v) { return vs::ismap(v); }
inline bool islist(const Value& v) { return vs::islist(v); }
inline bool iskey(const Value& v) { return vs::iskey(v); }
inline bool isempty(const Value& v) { return vs::isempty(v); }
inline bool isfunc(const Value& v) { return vs::isfunc(v); }

inline Value clone(const Value& v) { return vs::clone(v); }
inline int typify(const Value& v) { return vs::typify(v); }
inline long long size(const Value& v) { return vs::size(v); }

inline std::vector<Value> items(const Value& v) { return vs::items(v); }
inline std::vector<std::string> keysof(const Value& v) { return vs::keysof(v); }

inline std::string stringify(const Value& v) { return vs::stringify(v); }
inline std::string jsonify(const Value& v) { return vs::jsonify(v, 0); }
inline std::string escre(const Value& v) { return vs::escre(v); }
inline std::string escurl(const Value& v) { return vs::escurl(v); }
inline std::string join(const Value& arr, const std::string& sep, bool url) {
  return vs::join(arr, sep, url);
}

inline Value merge(const Value& list) { return vs::merge_v(list); }
inline Value transform(const Value& data, const Value& spec) {
  return vs::transform(data, spec);
}
inline Value validate(const Value& data, const Value& spec, const Value& opts) {
  return vs::validate(data, spec, opts);
}
inline std::vector<Value> select(const Value& obj, const Value& query) {
  return vs::select(obj, query);
}

// getpath / setpath with a key-list (java Struct.getpath(m, List.of(...))).
inline Value pathList(const std::vector<std::string>& keys) {
  auto l = std::make_shared<List>();
  for (const auto& k : keys) l->push_back(Value(k));
  return Value(std::move(l));
}
inline Value getpath(const Value& store, const std::vector<std::string>& keys) {
  return vs::getpath_v(store, pathList(keys));
}
inline Value getpath(const Value& store, std::initializer_list<std::string> keys) {
  return getpath(store, std::vector<std::string>(keys));
}
// setpath: mutate the shared store in place; return the ROOT store (NOT the
// inner node setpath_v returns — the value-semantics trap the rust port hit).
inline Value setpath(const Value& store, const std::vector<std::string>& keys, const Value& val) {
  vs::setpath_v(store, pathList(keys), val);
  return store;
}
inline Value setpath(const Value& store, std::initializer_list<std::string> keys,
                     const Value& val) {
  return setpath(store, std::vector<std::string>(keys), val);
}

} // namespace Struct

} // namespace sdk

#endif // SDK_CORE_STRUCT_HPP
