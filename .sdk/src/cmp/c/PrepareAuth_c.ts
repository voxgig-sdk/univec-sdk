
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
  // query parameter or a cookie, so the branch - and the base64 encoder it
  // needs, which the c core does not otherwise ship - is emitted only where
  // it can mean something.
  const withBasic = spec.basic && 'header' === spec.where

  const withStdio = 'query' !== spec.where

  const bag = bagName(spec.where)

  const head = `// prepare_auth utility (mirrors utility/prepare_auth.rs).
//
// GENERATED, not templated: where the credential goes - header, query or
// cookie, and under what name - is a fact about THIS API, and tm/ can only
// hold one answer. See PrepareAuth_c.

#include "sdk.h"

${withStdio ? `#include <stdio.h>
` : ''}#include <string.h>

#define CRED_NAME "${cstr(credLiteral(spec.where, spec.name))}"
${'cookie' === spec.where ? `#define COOKIE_HEADER "cookie"
` : ''}#define OPTION_APIKEY "apikey"
${withBasic ? `#define OPTION_SECRET "secret"
` : ''}#define NOT_FOUND "__NOTFOUND__"
${withBasic ? `
// The c core ships no base64 (the vendored encoder under
// feature/secrets/plugins/ is gated behind that feature and is not linked
// into a plain SDK), so the one placement that needs it carries its own.
static const char B64_ALPHABET[] =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void b64_encode(const char* in, char* out, size_t outcap) {
  size_t n = strlen(in);
  size_t o = 0;
  for (size_t i = 0; i < n; i += 3) {
    unsigned int v = (unsigned char)in[i] << 16;
    if (i + 1 < n) v |= (unsigned int)(unsigned char)in[i + 1] << 8;
    if (i + 2 < n) v |= (unsigned int)(unsigned char)in[i + 2];
    if (o + 5 > outcap) break;
    out[o++] = B64_ALPHABET[(v >> 18) & 0x3f];
    out[o++] = B64_ALPHABET[(v >> 12) & 0x3f];
    out[o++] = (i + 1 < n) ? B64_ALPHABET[(v >> 6) & 0x3f] : '=';
    out[o++] = (i + 2 < n) ? B64_ALPHABET[v & 0x3f] : '=';
  }
  out[o] = '\\0';
}
` : ''}
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
${clear(spec.where, 4)}
    return spec;
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
  // True HTTP Basic Auth needs TWO credentials, base64-joined - a single
  // token in the header (the branch below) can never authenticate against
  // an API that actually checks \`Authorization: Basic base64(user:pass)\`.
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

    if (skip || no_secret) {
${clear(spec.where, 6)}
    } else {
      voxgig_value* prefix_v = getpath2(options, "auth", "prefix");
      const char* auth_prefix = voxgig_is_string(prefix_v) ? voxgig_as_string(prefix_v) : "";
      char pair[1024];
      char b64[1400];
      snprintf(pair, sizeof(pair), "%s:%s",
               voxgig_is_string(apikey) ? voxgig_as_string(apikey) : "",
               voxgig_is_string(secret) ? voxgig_as_string(secret) : "");
      b64_encode(pair, b64, sizeof(b64));
      if (auth_prefix[0] == '\\0') {
        setp(headers, CRED_NAME, v_str(b64));
      } else {
        char buf[1536];
        snprintf(buf, sizeof(buf), "%s %s", auth_prefix, b64);
        setp(headers, CRED_NAME, v_str(buf));
      }
    }

    return spec;
  }
`

  return head + basicBlock + `
  if (skip) {
${clear(spec.where, 4)}
  } else {
${place(spec.where)}
  }

  return spec;
}
`
}


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


function clear(where: string, indent: number): string {
  const pad = ' '.repeat(indent)
  return `${pad}voxgig_value* k = voxgig_new_string(CRED_NAME);
${pad}voxgig_delprop(${bagName(where)}, k);
${pad}voxgig_release(k);`
}


function place(where: string): string {
  if ('query' === where) {
    return `    const char* apikey_val = voxgig_is_string(apikey) ? voxgig_as_string(apikey) : "";
    setp(query, CRED_NAME, v_str(apikey_val));`
  }

  if ('cookie' === where) {
    return `    const char* apikey_val = voxgig_is_string(apikey) ? voxgig_as_string(apikey) : "";
    const char* existing = get_str(headers, COOKIE_HEADER);
    char buf[2048];
    if (existing && existing[0] != '\\0') {
      snprintf(buf, sizeof(buf), "%s; %s=%s", existing, CRED_NAME, apikey_val);
    } else {
      snprintf(buf, sizeof(buf), "%s=%s", CRED_NAME, apikey_val);
    }
    setp(headers, COOKIE_HEADER, v_str(buf));`
  }

  return `    voxgig_value* prefix_v = getpath2(options, "auth", "prefix");
    const char* auth_prefix = voxgig_is_string(prefix_v) ? voxgig_as_string(prefix_v) : "";
    const char* apikey_val = voxgig_is_string(apikey) ? voxgig_as_string(apikey) : "";
    // A raw credential (empty prefix, e.g. an apiKey scheme) must go in
    // as-is; only a non-empty prefix (Bearer/Basic/OAuth) is space-joined.
    if (auth_prefix[0] == '\\0') {
      setp(headers, CRED_NAME, v_str(apikey_val));
    } else {
      char buf[1024];
      snprintf(buf, sizeof(buf), "%s %s", auth_prefix, apikey_val);
      setp(headers, CRED_NAME, v_str(buf));
    }`
}


function cstr(s: string): string {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}


export {
  PrepareAuth
}
