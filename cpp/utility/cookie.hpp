// Univec SDK: the cookie header, read one way everywhere.
#pragma once

#include <string>
#include <vector>

namespace sdk {
namespace util {

// The caller's cookie pieces with the named cookies removed: a cookie is one
// ;-delimited piece, whatever its value holds.
inline std::vector<std::string> cookieKeep(const std::string& header, const std::vector<std::string>& names) {
  auto trim = [](const std::string& s) {
    size_t a = s.find_first_not_of(" \t");
    size_t b = s.find_last_not_of(" \t");
    return std::string::npos == a ? std::string() : s.substr(a, b - a + 1);
  };
  std::vector<std::string> kept;
  size_t at = 0;
  while (at <= header.size()) {
    size_t end = header.find(';', at);
    if (std::string::npos == end) end = header.size();
    std::string cookie = trim(header.substr(at, end - at));
    std::string name = trim(cookie.substr(0, cookie.find('=')));
    bool owned = false;
    for (const auto& n : names) {
      if (n == name) owned = true;
    }
    if (!cookie.empty() && !owned) kept.push_back(cookie);
    at = end + 1;
  }
  return kept;
}

}  // namespace util
}  // namespace sdk
