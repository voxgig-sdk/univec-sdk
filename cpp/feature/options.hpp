// Univec SDK — shared feature option readers (mirrors java
// feature/FeatureOptions.java). Feature options arrive as struct Value
// maps; injectable clocks (now/sleep) arrive as struct function Values so
// tests can drive timing-based features deterministically.

#ifndef SDK_FEATURE_OPTIONS_HPP
#define SDK_FEATURE_OPTIONS_HPP

#include <chrono>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "../core/types.hpp"

namespace sdk {
namespace fopt {

inline bool foptBool(const Value& options, const std::string& key, bool def) {
  Value v = getp(options, key);
  return v.is_bool() ? v.as_bool() : def;
}

inline int foptInt(const Value& options, const std::string& key, int def) {
  Value v = getp(options, key);
  return v.is_number() ? static_cast<int>(v.as_int()) : def;
}

inline long long foptLong(const Value& options, const std::string& key, long long def) {
  Value v = getp(options, key);
  return v.is_number() ? static_cast<long long>(v.as_int()) : def;
}

inline double foptNum(const Value& options, const std::string& key, double def) {
  Value v = getp(options, key);
  return v.is_number() ? v.as_double() : def;
}

inline std::string foptStr(const Value& options, const std::string& key, const std::string& def) {
  Value v = getp(options, key);
  return (v.is_string() && !v.as_string().empty()) ? v.as_string() : def;
}

inline Value foptMap(const Value& options, const std::string& key) {
  Value v = getp(options, key);
  return v.is_map() ? v : Value::undef();
}

inline Value foptList(const Value& options, const std::string& key) {
  Value v = getp(options, key);
  return v.is_list() ? v : Value::undef();
}

inline std::vector<std::string> foptStrList(const Value& options, const std::string& key) {
  std::vector<std::string> out;
  Value raw = foptList(options, key);
  if (raw.is_list()) {
    for (const auto& v : *raw.as_list()) {
      if (v.is_string()) out.push_back(v.as_string());
    }
  }
  return out;
}

using SleepFn = std::function<void(int)>;
using NowFn = std::function<long long()>;

// The injectable sleep: option "sleep" is a struct func taking [ms].
inline SleepFn foptSleep(const Value& options) {
  Value v = getp(options, "sleep");
  if (v.is_injector()) {
    Value fn = v;
    return [fn](int ms) {
      vs::Injection inj(Value::undef(), Value::undef());
      fn.as_injector()(inj, vlist({Value(ms)}), std::string(""), Value::undef());
    };
  }
  return [](int ms) {
    if (ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds(ms));
  };
}

// The injectable clock: option "now" is a struct func returning ms.
inline NowFn foptNow(const Value& options) {
  Value v = getp(options, "now");
  if (v.is_injector()) {
    Value fn = v;
    return [fn]() -> long long {
      vs::Injection inj(Value::undef(), Value::undef());
      Value r = fn.as_injector()(inj, vlist(), std::string(""), Value::undef());
      return r.is_number() ? static_cast<long long>(r.as_int()) : 0;
    };
  }
  return []() -> long long {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
  };
}

// Header helpers (case-insensitive), operating on struct Value maps.
inline Value fheaderGet(const Value& headers, const std::string& name) {
  if (!headers.is_map()) return Value::undef();
  std::string lname = name;
  for (auto& c : lname) c = static_cast<char>(std::tolower((unsigned char)c));
  for (const auto& kv : *headers.as_map()) {
    std::string k = kv.first;
    for (auto& c : k) c = static_cast<char>(std::tolower((unsigned char)c));
    if (k == lname) return kv.second;
  }
  return Value::undef();
}

inline bool fheaderHas(const Value& headers, const std::string& name) {
  return !fheaderGet(headers, name).is_undef();
}

inline void fheaderSetDefault(const Value& headers, const std::string& name,
                              const std::string& value) {
  if (!headers.is_map()) return;
  if (fheaderHas(headers, name)) return;
  map_put(headers, name, Value(value));
}

inline int fresStatus(const Value& res) {
  if (!res.is_map()) return -1;
  Value s = getp(res, "status");
  return s.is_number() ? static_cast<int>(s.as_int()) : -1;
}

inline std::string fresHeader(const Value& res, const std::string& name) {
  if (!res.is_map()) return "";
  Value headers = getp(res, "headers");
  if (!headers.is_map()) return "";
  Value v = fheaderGet(headers, name);
  return v.is_string() ? v.as_string() : "";
}

inline int fparseInt(const std::string& s, int def) {
  try {
    size_t pos = 0;
    std::string t = s;
    size_t a = t.find_first_not_of(" \t");
    if (a != std::string::npos) t = t.substr(a);
    int r = std::stoi(t, &pos);
    return r;
  } catch (...) {
    return def;
  }
}

} // namespace fopt
} // namespace sdk

#endif // SDK_FEATURE_OPTIONS_HPP
