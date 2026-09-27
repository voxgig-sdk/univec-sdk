import {
  Content,
  File,
  Folder,
  cmp,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
  resolveAuthPrefix,
} from '@voxgig/sdkgen'


import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const PrepareAuth = cmp(async function PrepareAuth(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const active = authSwitchedOn(model)
  const where = resolveAuthIn(model)
  const name = resolveAuthName(model)
  const prefix = resolveAuthPrefix(model)
  const basic = isHttpBasicAuth(model)

  Folder({ name: 'utility' }, () => {
    File({ name: 'prepare_auth.' + target.ext }, () => {
      Content(render({ active, where, name, prefix, basic }))
    })
  })
})


function authSwitchedOn(model: any): boolean {
  const auth = getModelPath(model, `main.${KIT}.config.auth`,
    { only_active: false, required: false })
  return !(null != auth && false === auth.active)
}


type AuthSpec = {
  active: boolean
  where: string
  name: string
  prefix: string
  basic: boolean
}


function render(spec: AuthSpec): string {
  const bag = bagName(spec.where)

  // HTTP Basic is header-only by definition: the scheme is
  // `Authorization: Basic base64(user:pass)`. It cannot be expressed as a
  // query parameter or a cookie, so the branch — and the base64 encoder it
  // needs, which the cpp core does not otherwise ship — is emitted only
  // where it can mean something.
  const withBasic = spec.basic && 'header' === spec.where

  const head = `// prepare_auth utility — WHERE THE CREDENTIAL GOES.
//
// GENERATED, not templated: header, query or cookie, and under what name,
// is a fact about THIS API, and tm/ can only hold one answer. Extracted
// from utility/pipeline.hpp, which includes this header and still binds
// \`u.prepareAuth = util::prepareAuth\` in register_all — the symbol, the
// namespace and every call site are unchanged. See PrepareAuth_cpp.
//
// Do not hand-edit: change the model's security scheme (or
// main.kit.config.auth) and regenerate.

#ifndef SDK_UTILITY_PREPARE_AUTH_HPP
#define SDK_UTILITY_PREPARE_AUTH_HPP

${withBasic ? `#include <cstddef>
` : ''}#include <string>

#include "../core/types.hpp"

namespace sdk {
namespace util {

`

  const tail = `
} // namespace util
} // namespace sdk

#endif // SDK_UTILITY_PREPARE_AUTH_HPP
`

  // AUTH SWITCHED OFF BY THE PROJECT (see authSwitchedOn for why only an
  // EXPLICIT switch counts). The SDK gets a prepareAuth that is honest
  // about it rather than one that erases a header nobody set. The spec
  // guard stays, because makeSpec calls this unconditionally and the rest
  // of the pipeline relies on the SpecPtr coming back.
  if (!spec.active) {
    return head + `// This SDK is configured with authentication off
// (main.kit.config.auth.active: false), so there is no credential to place.
// The function stays in the pipeline because makeSpec calls it
// unconditionally and uses the Spec it returns.
inline SpecPtr prepareAuth(CtxPtr ctx) {
  SpecPtr spec = ctx->spec;
  if (!spec) throw ctx->makeError("auth_no_spec", "Expected context spec property to be defined.");

  return spec;
}
` + tail
  }

  const helpers = 'cookie' === spec.where ? cookieHelpers() : ''

  const basicHelper = !withBasic ? '' : `
// The cpp core ships no base64 (the vendored encoder under
// feature/secrets/ is compiled only behind that feature's plugin groups and
// is not linked into a plain SDK), so the one placement that needs it
// carries its own.
inline std::string authBase64(const std::string& in) {
  static const char* ALPHABET =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  std::string out;
  out.reserve(((in.size() + 2) / 3) * 4);
  for (size_t i = 0; i < in.size(); i += 3) {
    unsigned int v = static_cast<unsigned char>(in[i]) << 16;
    if (i + 1 < in.size()) v |= static_cast<unsigned int>(static_cast<unsigned char>(in[i + 1])) << 8;
    if (i + 2 < in.size()) v |= static_cast<unsigned int>(static_cast<unsigned char>(in[i + 2]));
    out += ALPHABET[(v >> 18) & 0x3f];
    out += ALPHABET[(v >> 12) & 0x3f];
    out += (i + 1 < in.size()) ? ALPHABET[(v >> 6) & 0x3f] : '=';
    out += (i + 2 < in.size()) ? ALPHABET[v & 0x3f] : '=';
  }
  return out;
}

`

  const preamble = `inline SpecPtr prepareAuth(CtxPtr ctx) {
  SpecPtr spec = ctx->spec;
  if (!spec) throw ctx->makeError("auth_no_spec", "Expected context spec property to be defined.");

  static const std::string CRED_NAME = ${cppstr(credLiteral(spec.where, spec.name))};
  static const std::string NOT_FOUND = "__NOTFOUND__";

  Value ${bag} = spec->${bag};
  Value options = ctx->client->optionsMap();

  // Public APIs that need no auth omit the options.auth block entirely, and
  // \`auth: null\` is the documented way to suppress a credential outright.
  if (is_nullish(getp(options, "auth"))) {
${clear(spec.where, 4)}
    return spec;
  }

  Value apikey = getp(options, "apikey", Value(NOT_FOUND));

  bool skip = false;
  if (is_nullish(apikey)) {
    skip = true;
  } else if (apikey.is_string() && (apikey.as_string() == NOT_FOUND || apikey.as_string().empty())) {
    skip = true;
  }
`

  const basicBlock = !withBasic ? '' : `
  // True HTTP Basic Auth needs TWO credentials, base64-joined - a single
  // token in the header (the branch below) can never authenticate against
  // an API that actually checks \`Authorization: Basic base64(user:pass)\`.
  if (is_true(Struct::getpath(options, {"auth", "basic"}))) {
    Value secret = getp(options, "secret", Value(NOT_FOUND));

    bool noSecret = false;
    if (is_nullish(secret)) {
      noSecret = true;
    } else if (secret.is_string() && (secret.as_string() == NOT_FOUND || secret.as_string().empty())) {
      noSecret = true;
    }

    if (skip || noSecret) {
${clear(spec.where, 6)}
    } else {
      std::string authPrefix = as_str(Struct::getpath(options, {"auth", "prefix"}));
      std::string b64 = authBase64(
        (apikey.is_string() ? apikey.as_string() : "") + ":" +
        (secret.is_string() ? secret.as_string() : ""));
      if (authPrefix.empty()) {
        map_put(headers, CRED_NAME, Value(b64));
      } else {
        map_put(headers, CRED_NAME, Value(authPrefix + " " + b64));
      }
    }

    return spec;
  }
`

  return head + helpers + basicHelper + preamble + basicBlock + `
  if (skip) {
${clear(spec.where, 4)}
  } else {
${place(spec.where)}
  }

  return spec;
}
` + tail
}


function cookieHelpers(): string {
  return `// The cookie header minus our own pair, every other cookie untouched.
inline std::string authCookieRest(const Value& headers, const std::string& cred) {
  std::string existing = as_str(getp(headers, "cookie"));
  if (existing.empty()) return "";

  std::string kept;
  size_t start = 0;
  while (start <= existing.size()) {
    size_t sep = existing.find(';', start);
    std::string piece = (std::string::npos == sep)
      ? existing.substr(start) : existing.substr(start, sep - start);

    size_t a = piece.find_first_not_of(" \\t");
    size_t b = piece.find_last_not_of(" \\t");
    piece = (std::string::npos == a) ? "" : piece.substr(a, b - a + 1);

    bool ours = piece == cred || 0 == piece.compare(0, cred.size() + 1, cred + "=");
    if (!piece.empty() && !ours) {
      if (!kept.empty()) kept += "; ";
      kept += piece;
    }

    if (std::string::npos == sep) break;
    start = sep + 1;
  }

  return kept;
}


// Set (remove=false) or drop (remove=true) our pair, leaving the rest in place.
inline void authCookieApply(const Value& headers, const std::string& cred,
                            const std::string& value, bool remove) {
  std::string rest = authCookieRest(headers, cred);

  if (remove) {
    if (rest.empty()) {
      map_remove(headers, "cookie");
    } else {
      map_put(headers, "cookie", Value(rest));
    }
    return;
  }

  std::string pair = cred + "=" + value;
  map_put(headers, "cookie", Value(rest.empty() ? pair : rest + "; " + pair));
}


`
}


function credLiteral(where: string, name: string): string {
  return 'header' === where ? String(name).toLowerCase() : String(name)
}


function bagName(where: string): string {
  return 'query' === where ? 'query' : 'headers'
}


function clear(where: string, indent: number): string {
  const pad = ' '.repeat(indent)

  if ('cookie' === where) {
    return `${pad}authCookieApply(headers, CRED_NAME, "", true);`
  }

  return `${pad}map_remove(${bagName(where)}, CRED_NAME);`
}


function place(where: string): string {
  if ('query' === where) {
    return `    map_put(query, CRED_NAME, Value(apikey.is_string() ? apikey.as_string() : ""));`
  }

  if ('cookie' === where) {
    return `    authCookieApply(headers, CRED_NAME,
      apikey.is_string() ? apikey.as_string() : "", false);`
  }

  return `    std::string authPrefix = as_str(Struct::getpath(options, {"auth", "prefix"}));
    std::string apikeyVal = apikey.is_string() ? apikey.as_string() : "";
    // A raw credential (empty prefix, e.g. an apiKey scheme) must go in
    // as-is; only a non-empty prefix (Bearer/Basic/OAuth) is space-joined.
    if (authPrefix.empty()) {
      map_put(headers, CRED_NAME, Value(apikeyVal));
    } else {
      map_put(headers, CRED_NAME, Value(authPrefix + " " + apikeyVal));
    }`
}


function cppstr(s: string): string {
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'
}


export {
  PrepareAuth
}
