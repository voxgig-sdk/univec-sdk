// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/src/Json.hpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The JSON this port owns.
//
// C++ has no JSON in its standard library, and nlohmann/json, RapidJSON
// and Boost.PropertyTree are all packages - so the value model, the parser
// and the writer are here. What the providers need of JSON is small: read
// a field out of a vault's answer, and build a request body.
//
// Objects keep INSERTION order (a vector of pairs, not a std::map, which
// orders by key): a signed payload's field order is part of what was
// signed, and the shared spec compares whole maps.
//
// A port of typescript/src/Json.ts, which is canonical.

#ifndef SEKRETO_JSON_HPP
#define SEKRETO_JSON_HPP

#include <initializer_list>
#include <string>
#include <utility>
#include <vector>

namespace sekreto {

class Json {
 public:
  // Six cases, and numbers are doubles only: JSON has one number type, and
  // an integer case here would round-trip differently from every other
  // port. `numstr` puts an integral double back as an integer.
  enum class Type { Null, Bool, Num, Str, Arr, Obj };

  Type type = Type::Null;
  bool boolval = false;
  double numval = 0;
  std::string strval;
  std::vector<Json> arrval;
  std::vector<std::pair<std::string, Json>> objval;

  Json() = default;

  static Json null();
  static Json boolean(bool val);
  static Json num(double val);
  static Json str(const std::string& val);
  static Json arr(std::vector<Json> entries);
  static Json obj(std::vector<std::pair<std::string, Json>> entries);

  bool isnull() const { return Type::Null == type; }
  bool isbool() const { return Type::Bool == type; }
  bool isnum() const { return Type::Num == type; }
  bool isstr() const { return Type::Str == type; }
  bool isarr() const { return Type::Arr == type; }
  bool isobj() const { return Type::Obj == type; }

  // One step down an object, for reading a vault's answer. A missing key,
  // or a step through anything that is not an object, yields Null - which
  // every caller reads as "no value", so a chain of steps needs no guards.
  Json get(const std::string& key) const;

  // Typed accessors. Each answers nothing for the wrong type: `__type`
  // must be a string, a 1Password vault list an array, a Doppler config an
  // object, or the value is not what the protocol promised.
  bool asstr(std::string& out) const;
  bool asnum(double& out) const;

  // Printable text, or nothing. JSON Null yields NOTHING rather than the
  // string "null", so a null field is a miss and never the four letters.
  bool text(std::string& out) const;

  // Parse. FAILURE IS NOT NULL: `false` means "this text is not JSON",
  // which fetchjson has to tell apart from "this text is the literal
  // null". No exception escapes.
  static bool parse(const std::string& text, Json& out);

  static std::string stringify(const Json& val);

  // Public, because the CLI assembles its output line field by field.
  static std::string quote(const std::string& text);

  // An integral double below 2^53 prints as an integer, so a JSON 1
  // round-trips as 1 and not 1.0.
  static std::string numstr(double val);
};

}  // namespace sekreto

#endif
