
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
    File({ name: 'prepare_auth.c' }, () => {
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

  if (!spec.active) {
    return `// prepare_auth utility (mirrors utility/prepare_auth.rs).
//
// GENERATED, not templated - see PrepareAuth_c.
//
// This API declares no authentication, so there is no credential to place.
// The function stays in the pipeline because make_spec calls it
// unconditionally.

#include "sdk.h"

Spec* prepare_auth_util(Context* ctx, PNError** err) {
  *err = NULL;
  Spec* spec = ctx->spec;
  if (!spec) {
    *err = context_make_error(ctx, "auth_no_spec", "Expected context spec property to be defined.");
    return NULL;
  }

  return spec;
}
`
  }

  // HTTP Basic is header-only by definition: the scheme is
  // `Authorization: Basic base64(user:pass)`. It cannot be expressed as a
  // query parameter or a cookie, so the branch is emitted only where it can
  // mean something. The encoder is the clean utility's, which needs it for
  // the base64 form of every registered value.
  const withBasic = spec.basic && 'header' === spec.where

  const header = 'header' === spec.where
  const cookie = 'cookie' === spec.where

  const bag = bagName(spec.where)

  const head = `// prepare_auth utility (mirrors utility/prepare_auth.rs).
//
// GENERATED, not templated: where the credential goes - header, query or
// cookie, and under what name - is a fact about THIS API, and tm/ can only
// hold one answer. See PrepareAuth_c.

#include "sdk.h"

${header ? `#include <stdio.h>
` : ''}#include <stdlib.h>
#include <string.h>

#define CRED_NAME "${cstr(credLiteral(spec.where, spec.name))}"
${cookie ? `#define COOKIE_HEADER "cookie"
` : ''}#define OPTION_APIKEY "apikey"
${withBasic ? `#define OPTION_SECRET "secret"
` : ''}#define NOT_FOUND "__NOTFOUND__"

${header ? `// The client's auth.name option, when set, replaces the name the API
// declares. A run-time name is lower-cased into *owned, which the caller
// frees; NULL when that copy cannot be allocated.
static const char* auth_name(voxgig_value* options, char** owned) {
  *owned = NULL;
  voxgig_value* v = getpath2(options, "auth", "name");
  const char* name = voxgig_is_string(v) ? voxgig_as_string(v) : NULL;
  if (NULL == name || '\\0' == name[0]) return CRED_NAME;
  size_t n = strlen(name);
  char* lower = (char*)malloc(n + 1);
  if (NULL == lower) return NULL;
  // ASCII rules, as a field name is ASCII: tolower follows the C locale.
  for (size_t i = 0; i <= n; i++) {
    char c = name[i];
    lower[i] = ('A' <= c && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
  }
  *owned = lower;
  return lower;
}` : `// The client's auth.name option, when set, replaces the name the API declares.
static const char* auth_name(voxgig_value* options) {
  voxgig_value* v = getpath2(options, "auth", "name");
  const char* name = voxgig_is_string(v) ? voxgig_as_string(v) : NULL;
  return (NULL == name || '\\0' == name[0]) ? CRED_NAME : name;
}`}
${header ? JOIN_HELPER : ''}${cookie ? COOKIE_HELPER : ''}
// Places or clears the credential under name, the one in effect.
static Spec* prepare_auth_as(Context* ctx, Spec* spec, voxgig_value* ${bag},
                             voxgig_value* options,${withBasic ? ' voxgig_value* auth,' : ''} const char* name,
                             PNError** err) {
  // A credential left under the declared name would travel beside the renamed one.
  if (0 != strcmp(name, CRED_NAME)) {
${clear(spec.where, 'CRED_NAME', 4)}
  }

  voxgig_value* akey_key = voxgig_new_string(OPTION_APIKEY);
  voxgig_value* nf = voxgig_new_string(NOT_FOUND);
  voxgig_value* apikey = voxgig_getprop(options, akey_key, nf);
  voxgig_release(akey_key);
  voxgig_release(nf);

  bool skip;
  if (v_is_noval(apikey) || v_is_null(apikey)) {
    skip = true;
  } else if (voxgig_is_string(apikey)) {
    const char* s = voxgig_as_string(apikey);
    skip = (strcmp(s, NOT_FOUND) == 0 || s[0] == '\\0');
  } else {
    skip = false;
  }
`

  const basicBlock = !withBasic ? '' : `
  // True HTTP Basic Auth joins the two credentials, base64-encoded - a single
  // token in the header (the branch below) can never authenticate against
  // an API that actually checks \`Authorization: Basic base64(user:pass)\`.
  // The password may be empty (RFC 7617): Lob, for one, documents the key as
  // the user with a blank password (\`curl -u key:\`).
  bool want_basic = false;
  get_bool(auth, "basic", &want_basic);
  if (want_basic) {
    voxgig_value* sec_key = voxgig_new_string(OPTION_SECRET);
    voxgig_value* snf = voxgig_new_string(NOT_FOUND);
    voxgig_value* secret = voxgig_getprop(options, sec_key, snf);
    voxgig_release(sec_key);
    voxgig_release(snf);

    bool no_secret;
    if (v_is_noval(secret) || v_is_null(secret)) {
      no_secret = true;
    } else if (voxgig_is_string(secret)) {
      const char* s = voxgig_as_string(secret);
      no_secret = (strcmp(s, NOT_FOUND) == 0 || s[0] == '\\0');
    } else {
      no_secret = false;
    }

    if (skip) {
${clear(spec.where, 'name', 6)}
    } else {
      voxgig_value* prefix_v = getpath2(options, "auth", "prefix");
      const char* auth_prefix = voxgig_is_string(prefix_v) ? voxgig_as_string(prefix_v) : "";
      const char* user = voxgig_is_string(apikey) ? voxgig_as_string(apikey) : "";
      const char* pass = !no_secret && voxgig_is_string(secret) ? voxgig_as_string(secret) : "";
      char* pair = auth_join(user, ":", pass);
      if (NULL == pair) {
        *err = context_make_error(ctx, "auth_alloc", "Could not allocate the credential.");
        return NULL;
      }
      char* b64 = clean_base64(pair);
      free(pair);
      // The joined, encoded pair is a wire form neither credential's own
      // registration covers.
      clean_add_util(ctx, b64);
${setHeader('b64', 6)}
    }

    return spec;
  }
`

  return head + basicBlock + `
  if (skip) {
${clear(spec.where, 'name', 4)}
  } else {
${place(spec.where)}
  }

  return spec;
}

Spec* prepare_auth_util(Context* ctx, PNError** err) {
  *err = NULL;
  Spec* spec = ctx->spec;
  if (!spec) {
    *err = context_make_error(ctx, "auth_no_spec", "Expected context spec property to be defined.");
    return NULL;
  }

  voxgig_value* ${bag} = spec->${bag};
  voxgig_value* options = ctx->client ? sdk_options_map(ctx->client) : ctx->options;

  voxgig_value* auth = getp(options, "auth");
  if (v_is_noval(auth) || v_is_null(auth)) {
${clear(spec.where, 'CRED_NAME', 4)}
    return spec;
  }
${header ? `
  char* owned = NULL;
  const char* name = auth_name(options, &owned);
  if (NULL == name) {
    *err = context_make_error(ctx, "auth_alloc", "Could not allocate the credential name.");
    return NULL;
  }

  Spec* out = prepare_auth_as(ctx, spec, ${bag}, options,${withBasic ? ' auth,' : ''} name, err);
  free(owned);
  return out;` : `
  return prepare_auth_as(ctx, spec, ${bag}, options, auth_name(options), err);`}
}
`
}


const JOIN_HELPER = `
// a, sep and b joined, in a buffer allocated to fit; NULL when it cannot be.
static char* auth_join(const char* a, const char* sep, const char* b) {
  size_t n = strlen(a) + strlen(sep) + strlen(b) + 1;
  char* out = (char*)malloc(n);
  if (NULL != out) snprintf(out, n, "%s%s%s", a, sep, b);
  return out;
}
`


// Spliced rather than appended, in a buffer sized to fit the whole header.
const COOKIE_HELPER = `
static bool cred_named(const char* name, size_t nlen, void* ud) {
  const char* cred = (const char*)ud;
  return strlen(cred) == nlen && 0 == strncmp(cred, name, nlen);
}

// Rewrite the cookie header with the named pair removed, then set to value
// when value is not NULL; every other cookie is kept in order. False only
// when the new header could not be allocated.
static bool auth_cookie_set(voxgig_value* headers, const char* name, const char* value) {
  const char* existing = get_str(headers, COOKIE_HEADER);
  char* kept = NULL == existing ? NULL : cookie_keep(existing, cred_named, (void*)name);
  size_t klen = NULL == kept ? 0 : strlen(kept);
  size_t name_len = strlen(name);
  size_t value_len = NULL == value ? 0 : strlen(value);
  char* out = (char*)malloc(klen + name_len + value_len + 4);
  if (NULL == out) {
    free(kept);
    return false;
  }
  size_t used = klen;
  if (0 != klen) memcpy(out, kept, klen);
  free(kept);
  if (NULL != value) {
    if (0 != used) { out[used++] = ';'; out[used++] = ' '; }
    memcpy(out + used, name, name_len);
    used += name_len;
    out[used++] = '=';
    memcpy(out + used, value, value_len);
    used += value_len;
  }
  out[used] = '\\0';
  if (0 != used) {
    setp(headers, COOKIE_HEADER, v_str(out));
  } else {
    voxgig_value* k = voxgig_new_string(COOKIE_HEADER);
    voxgig_delprop(headers, k);
    voxgig_release(k);
  }
  free(out);
  return true;
}
`


function credLiteral(where: string, name: string): string {
  return 'header' === where ? String(name).toLowerCase() : String(name)
}


// The bag the credential lands in, per placement. It is both the local
// variable name and the Spec field, which in c are spelled the same
// (spec->headers / spec->query). Cookies ride the header bag because a
// cookie IS a header.
function bagName(where: string): string {
  return 'query' === where ? 'query' : 'headers'
}


function clear(where: string, name: string, indent: number): string {
  const pad = ' '.repeat(indent)
  if ('cookie' === where) {
    return cookieCall(name, 'NULL', pad)
  }
  return `${pad}voxgig_value* k = voxgig_new_string(${name});
${pad}voxgig_delprop(${bagName(where)}, k);
${pad}voxgig_release(k);`
}


function cookieCall(name: string, value: string, pad: string): string {
  return `${pad}if (!auth_cookie_set(headers, ${name}, ${value})) {
${pad}  *err = context_make_error(ctx, "auth_alloc", "Could not allocate the cookie header.");
${pad}  return NULL;
${pad}}`
}


// A raw credential (empty prefix, e.g. an apiKey scheme) goes in as-is;
// only a non-empty prefix (Bearer/Basic/OAuth) is space-joined.
function setHeader(value: string, indent: number): string {
  const pad = ' '.repeat(indent)
  return `${pad}if (auth_prefix[0] == '\\0') {
${pad}  setp(headers, name, v_str(${value}));
${pad}} else {
${pad}  char* joined = auth_join(auth_prefix, " ", ${value});
${pad}  if (NULL == joined) {
${pad}    *err = context_make_error(ctx, "auth_alloc", "Could not allocate the credential.");
${pad}    return NULL;
${pad}  }
${pad}  setp(headers, name, v_str(joined));
${pad}  free(joined);
${pad}}`
}


function place(where: string): string {
  if ('query' === where) {
    return `    const char* apikey_val = voxgig_is_string(apikey) ? voxgig_as_string(apikey) : "";
    setp(query, name, v_str(apikey_val));`
  }

  if ('cookie' === where) {
    return `    const char* apikey_val = voxgig_is_string(apikey) ? voxgig_as_string(apikey) : "";
${cookieCall('name', 'apikey_val', '    ')}`
  }

  return `    voxgig_value* prefix_v = getpath2(options, "auth", "prefix");
    const char* auth_prefix = voxgig_is_string(prefix_v) ? voxgig_as_string(prefix_v) : "";
    const char* apikey_val = voxgig_is_string(apikey) ? voxgig_as_string(apikey) : "";
${setHeader('apikey_val', 4)}`
}


function cstr(s: string): string {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}


export {
  PrepareAuth
}
