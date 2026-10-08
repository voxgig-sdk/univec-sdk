// prepare_auth utility — WHERE THE CREDENTIAL GOES.
//
// GENERATED, not templated: header, query or cookie, and under what name,
// is a fact about THIS API, and tm/ can only hold one answer. Extracted
// from utility/pipeline.hpp, which includes this header and still binds
// `u.prepareAuth = util::prepareAuth` in register_all — the symbol, the
// namespace and every call site are unchanged. See PrepareAuth_cpp.
//
// Do not hand-edit: change the model's security scheme (or
// main.kit.config.auth) and regenerate.

#ifndef SDK_UTILITY_PREPARE_AUTH_HPP
#define SDK_UTILITY_PREPARE_AUTH_HPP

#include <algorithm>
#include <string>

#include "../core/types.hpp"

namespace sdk {
namespace util {

inline SpecPtr prepareAuth(CtxPtr ctx) {
  SpecPtr spec = ctx->spec;
  if (!spec) throw ctx->makeError("auth_no_spec", "Expected context spec property to be defined.");

  static const std::string CRED_NAME = "authorization";
  static const std::string NOT_FOUND = "__NOTFOUND__";

  Value headers = spec->headers;
  Value options = ctx->client->optionsMap();

  // Public APIs that need no auth omit the options.auth block entirely, and
  // `auth: null` is the documented way to suppress a credential outright.
  if (is_nullish(getp(options, "auth"))) {
    map_remove(headers, CRED_NAME);
    return spec;
  }

  // The client's auth.name option, when set, replaces the name the API declares.
  std::string name = as_str(Struct::getpath(options, {"auth", "name"}));
  if (name.empty()) {
    name = CRED_NAME;
  } else {
    // ASCII rules, as a field name is ASCII: std::tolower follows the C locale.
    std::transform(name.begin(), name.end(), name.begin(),
      [](char c) { return ('A' <= c && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c; });
  }

  // A credential left under the declared name would travel beside the renamed one.
  if (name != CRED_NAME) {
    map_remove(headers, CRED_NAME);
  }

  Value apikey = getp(options, "apikey", Value(NOT_FOUND));

  bool skip = false;
  if (is_nullish(apikey)) {
    skip = true;
  } else if (apikey.is_string() && (apikey.as_string() == NOT_FOUND || apikey.as_string().empty())) {
    skip = true;
  }

  if (skip) {
    map_remove(headers, name);
  } else {
    std::string authPrefix = as_str(Struct::getpath(options, {"auth", "prefix"}));
    std::string apikeyVal = apikey.is_string() ? apikey.as_string() : "";
    // A raw credential (empty prefix, e.g. an apiKey scheme) must go in
    // as-is; only a non-empty prefix (Bearer/Basic/OAuth) is space-joined.
    if (authPrefix.empty()) {
      map_put(headers, name, Value(apikeyVal));
    } else {
      map_put(headers, name, Value(authPrefix + " " + apikeyVal));
    }
  }

  return spec;
}

} // namespace util
} // namespace sdk

#endif // SDK_UTILITY_PREPARE_AUTH_HPP
