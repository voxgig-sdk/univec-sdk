
import {
  Content,
  File,
  Folder,
  cmp,
  configDefinition,
  configReprSetting,
  each,
  isAuthActive,
  isConfigData,
  resolveAuthIn,
  resolveAuthName,
  resolveAuthPrefix,
  targetFeatures,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


import {
  cStringLiteral,
  formatCValue,
} from './utility_c'


function pluginDefinitions(model: Model, target: any):
  Record<string, { syms: string[], groups: number }> {
  const out: Record<string, { syms: string[], groups: number }> = {}
  const feature = targetFeatures(model, target)

  each(feature, (f: any) => {
    const declared = getModelPath(model,
      `main.${KIT}.feature.${f.name}.plugin`,
      { required: false, only_active: false }) || {}
    if (0 === Object.keys(declared).length) return

    const syms = new Set<string>()
    let groups = 0
    each(declared, (plugin: any) => {
      // Filter on `active` HERE rather than trusting the feature object to
      // arrive filtered (Config_go's note): getting this wrong names a
      // constructor for a file the trim just deleted.
      if (true !== plugin.active) return
      const defs = Object.keys(plugin.def?.[target.name] || {})
      if (0 < defs.length) groups++
      for (const sym of defs) syms.add(sym)
    })

    out[f.name] = { syms: Array.from(syms).sort(), groups }
  })

  return out
}


const FeaturePlugins = cmp(async function FeaturePlugins(props: any) {
  const ctx$ = props.ctx$
  const target = props.target
  const model: Model = ctx$.model

  const defs = pluginDefinitions(model, target)
  if (0 === Object.keys(defs).length) return

  Folder({ name: 'feature' }, () => {
    for (const fname of Object.keys(defs).sort()) {
      const { syms, groups } = defs[fname]

      Folder({ name: fname }, () => {
        File({ name: 'kinds.mk' }, () => {
          Content(`# Generated beside kinds.c: what the \`${fname}\` feature needs from the
# build, read by the Makefile through \`-include $(wildcard feature/*/kinds.mk)\`.
# Without this file none of the feature's vendored payload is compiled or
# linked. Do not hand-edit - change the model and regenerate.

# The vendored cores every chain needs (sekreto and the voxgig/plugin host it
# is built on), and the feature's gated suite.
FEATURE_SRCS += $(wildcard feature/${fname}/sekreto/*.c feature/${fname}/plugin/*.c)
FEATURE_TEST_SRCS += $(wildcard tests/feature/${fname}/*.c)
`)
          if (0 === groups) {
            Content(`
# No plugin group is active: the plugin layer (the kinds, the socket HTTP
# client and its OpenSSL binding, the encoders, the clock and the
# child-process launcher) is on disk but NOT compiled, and nothing beyond
# libc is linked. A chain of built-ins needs none of it.
`)
          }
          else {
            Content(`
# A plugin group is active: the selected kinds and the five shared helpers
# they call (the socket HTTP client and its OpenSSL binding, the encoders,
# the clock and the child-process launcher), with the two external
# libraries they bring - OpenSSL for the vault kinds' TLS, libcurl for the
# token-exchange transport of last resort in kinds.c.
FEATURE_SRCS += $(wildcard feature/${fname}/plugins/*.c)
LDLIBS += -lssl -lcrypto -lcurl
`)
          }
        })

        File({ name: 'kinds.c' }, () => {
          Content(`// Generated: the plugin definitions the model selected for the \`${fname}\`
// feature's provider chain (the c peer of go's core.FeaturePlugins), read
// back by core/config.c's feature_plugins("${fname}", &n).
//
// GENERATED beside kinds.mk, the build wiring tm/c/Makefile includes. Do
// not hand-edit - change the model's plugin groups and regenerate.

#include "sdk.h"

#include "sekreto.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// One prototype per selected kind: the \`Definition *(void)\` constructor
// its vendored file defines (plugins/sekretoplugins.h declares all ten;
// naming only these keeps the link line the boundary upstream intends).
${syms.map((sym: string) => `Definition* ${sym}(void);
`).join('')}
${0 === syms.length ?
`// No plugin group is active: the chain can name the four built-in kinds
// (env, memory, dotenv, file) and a custom provider, and nothing else.
void** ${fname}_plugins(size_t* n) {
  *n = 0;
  return NULL;
}
` :
`static void* ${fname.toUpperCase()}_KINDS[${syms.length}];

void** ${fname}_plugins(size_t* n) {
${syms.map((sym: string, i: number) => `  ${fname.toUpperCase()}_KINDS[${i}] = ${sym}();
`).join('')}  *n = ${syms.length};
  return ${fname.toUpperCase()}_KINDS;
}
`}`)

          if ('secrets' !== fname) return

          if (0 === groups) {
            Content(`
// THE EXCHANGE TRANSPORT OF LAST RESORT, when no plugin group is active:
// there is none. The c core ships no HTTP client, and libcurl is bundled
// with the plugin groups only (see tm/c/Makefile), so a token purchase
// needs options.system.fetch - the seam every live c request already uses.
// Reached only by an exchange whose caller supplied no transport; a chain
// that resolves a static credential never comes here.
voxgig_value* secrets_rawfetch(Context* ctx, const char* url,
                               voxgig_value* fetchdef, PNError** err) {
  (void)url; (void)fetchdef;
  *err = context_make_error(ctx, "secrets_no_transport",
    "secrets: the token exchange has no HTTP transport: this SDK selected no "
    "secrets plugin group, so libcurl is not linked; supply "
    "options.system.fetch or activate a plugin group");
  return NULL;
}
`)
            return
          }

          Content(`
// THE EXCHANGE TRANSPORT OF LAST RESORT (go's rawExchangeFetch): plain
// libcurl, answering the same transport-shaped map the system.fetch seam
// promises ({status, statusText, headers, json(), body}). It exists so an
// exchange works with ordinary SDK options - requiring a custom transport
// for the COMMON case would refuse every live token purchase before a
// request was made. Deliberately NOT the SDK transport: that is what the
// secrets feature wraps, and sending the token request back through it
// would recurse on the first expiry.
//
// libcurl is linked because a plugin group is active in this model; the
// Makefile adds -lcurl on exactly that condition.

#include <curl/curl.h>

typedef struct {
  char* data;
  size_t len;
} SecretsBuf;

static size_t secrets_curl_write(char* ptr, size_t size, size_t nmemb, void* ud) {
  SecretsBuf* b = (SecretsBuf*)ud;
  size_t add = size * nmemb;
  char* grown = (char*)realloc(b->data, b->len + add + 1);
  if (NULL == grown) return 0;
  b->data = grown;
  memcpy(b->data + b->len, ptr, add);
  b->len += add;
  b->data[b->len] = '\\0';
  return add;
}

voxgig_value* secrets_rawfetch(Context* ctx, const char* url,
                               voxgig_value* fetchdef, PNError** err) {
  static bool inited = false;
  *err = NULL;
  if (!inited) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    inited = true;
  }

  CURL* curl = curl_easy_init();
  if (NULL == curl) {
    *err = context_make_error(ctx, "secrets_transport", "secrets: curl_easy_init failed");
    return NULL;
  }

  const char* method = get_str(fetchdef, "method");
  if (NULL == method || '\\0' == method[0]) method = "POST";

  struct curl_slist* hdrs = NULL;
  voxgig_value* headers = getp(fetchdef, "headers");
  if (voxgig_is_map(headers)) {
    voxgig_map* hm = voxgig_as_map(headers);
    for (size_t i = 0; i < hm->len; i++) {
      if (!voxgig_is_string(hm->entries[i].value)) continue;
      size_t klen = strlen(hm->entries[i].key);
      const char* v = voxgig_as_string(hm->entries[i].value);
      char* line = (char*)malloc(klen + 2 + strlen(v) + 1);
      sprintf(line, "%s: %s", hm->entries[i].key, v);
      hdrs = curl_slist_append(hdrs, line);
      free(line);
    }
  }

  SecretsBuf body = {NULL, 0};
  curl_easy_setopt(curl, CURLOPT_URL, url);
  curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, secrets_curl_write);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
  const char* reqbody = get_str(fetchdef, "body");
  if (NULL != reqbody) {
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, reqbody);
  }

  CURLcode rc = curl_easy_perform(curl);
  long status = 0;
  if (CURLE_OK == rc) {
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
  }
  curl_slist_free_all(hdrs);
  curl_easy_cleanup(curl);

  if (CURLE_OK != rc) {
    char msg[512];
    snprintf(msg, sizeof(msg), "secrets: token exchange transport failed: %s (URL was: \\"%s\\")",
             curl_easy_strerror(rc), url);
    free(body.data);
    *err = context_make_error(ctx, "secrets_transport", msg);
    return NULL;
  }

  const char* text = body.data ? body.data : "";
  voxgig_value* parsed = json_parse(text);
  voxgig_value* out = cmap(5,
    "status", v_num((double)status),
    "statusText", v_str(status >= 400 ? "ERR" : "OK"),
    "headers", v_map(),
    "json", json_thunk(parsed),
    "body", v_str(text));
  free(body.data);
  return out;
}
`)
        })
      })
    }
  })
})


// core/config.c: make_config() builds the embedded API model as a Value;
// make_feature(name) is the N-feature-safe factory the client uses to
// instantiate features named in the options (mirrors Config_rust).
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  const authActive = isAuthActive(model)
  const authPrefix = resolveAuthPrefix(model)
  // `in` and `name` travel with the prefix now. They were resolved by apidef
  // all along and dropped here, so an apiKey-in-query API got an
  // Authorization header it does not read. Emitted only when they differ from
  // the defaults, so a header/Authorization SDK's config.c is byte-identical
  // to what it generated before (Config_ts and Config_go do the same).
  const authIn = resolveAuthIn(model)
  const authName = resolveAuthName(model)

  let baseUrl = ''
  try { baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`) } catch (_e) { }

  const { def: configDef, json: configJson } = configDefinition(model, target.name)
  const asData = isConfigData(configJson, configReprSetting(model))

  // The feature block comes from configDefinition's def, not from f.config,
  // so the literal carries each feature's `transport` role (station design
  // §8.4) beside its options and cannot drift from the data rep.
  const featureConfig: any = {}
  each(feature, (f: any) => {
    featureConfig[f.name] = configDef.feature[f.name] || {}
  })

  const entityOptions: any = {}
  each(entity, (ent: any) => {
    entityOptions[ent.name] = {}
  })

  const options: any = {
    base: baseUrl,
    headers,
    entity: entityOptions,
  }
  if (authActive) {
    options.auth = { prefix: authPrefix }
    if ('header' !== authIn) {
      options.auth.in = authIn
    }
    if ('Authorization' !== authName) {
      options.auth.name = authName
    }
  }

  const entityConfig = configDef.entity

  const config = {
    // main from configDefinition's def, not re-derived here, so the literal
    // rep and the data rep cannot disagree on identity (the Config_ts
    // #MainMeta discipline): name plus slug/version/target.
    main: configDef.main,
    feature: featureConfig,
    options,
    entity: entityConfig,
  }

  File({ name: 'config.c' }, () => {

    if (asData) {
      Content(`// Generated API configuration (mirrors core/config.go).

#include "api.h"

#include <string.h>

// THE API MODEL, EMBEDDED AS DATA (sdkgen rung L1).
//
// Emitted only above a size threshold, or when \`main.kit.config.repr\` pins
// it: for a small model the cmap() literal is smaller and far easier to read
// when debugging.
static const char CONFIG_DATA[] =
${cStringLiteral(configJson)};

voxgig_value* make_config(void) {
  return json_parse(CONFIG_DATA);
}

// SHARED CONFIG (sdkgen rung L2).
//
// The SDK reads the config on every request and never writes to it, so one
// instance is shared by every client rather than rebuilt per client. Above the
// size threshold make_config re-parses the whole embedded JSON, so this is the
// difference between parsing the model once and once per client.
//
// Deliberately never freed: it lives for the life of the process, like any
// other program-lifetime singleton.
static voxgig_value* shared_config_val = NULL;

// The process-wide config, built once on first use.
//
// The returned value is SHARED: treat it as read-only. Callers that need to
// mutate should use make_config, which always returns a fresh copy.
voxgig_value* shared_config(void) {
  if (NULL == shared_config_val) {
    shared_config_val = make_config();
  }
  return shared_config_val;
}
`)
    }
    else {

    Content(`// Generated API configuration (mirrors core/config.go).

#include "api.h"

#include <string.h>

voxgig_value* make_config(void) {
  return ${formatCValue(config, 1)};
}

// SHARED CONFIG (sdkgen rung L2).
//
// The SDK reads the config on every request and never writes to it, so one
// instance is shared by every client rather than rebuilt per client. Above the
// size threshold make_config re-parses the whole embedded JSON, so this is the
// difference between parsing the model once and once per client.
//
// Deliberately never freed: it lives for the life of the process, like any
// other program-lifetime singleton.
static voxgig_value* shared_config_val = NULL;

// The process-wide config, built once on first use.
//
// The returned value is SHARED: treat it as read-only. Callers that need to
// mutate should use make_config, which always returns a fresh copy.
voxgig_value* shared_config(void) {
  if (NULL == shared_config_val) {
    shared_config_val = make_config();
  }
  return shared_config_val;
}
`)
    }

    const featureNames = new Set<string>()
    each(feature, (f: any) => {
      if (f.name && f.name !== 'base') featureNames.add(f.name)
    })
    const sortedNames = Array.from(featureNames).sort()

    Content(`
`)
    for (const fname of sortedNames) {
      Content(`Feature* feature_${fname}_new(void);
`)
    }

    Content(`
Feature* make_feature(const char* name) {
`)
    for (const fname of sortedNames) {
      Content(`  if (strcmp(name, "${fname}") == 0) return feature_${fname}_new();
`)
    }

    Content(`  return feature_base_new();
}
`)

    const plugged = Object.keys(pluginDefinitions(model, target)).sort()

    Content(`
`)
    for (const fname of plugged) {
      Content(`void** ${fname}_plugins(size_t* n);
`)
    }

    Content(`
void** feature_plugins(const char* name, size_t* n) {
`)
    for (const fname of plugged) {
      Content(`  if (strcmp(name, "${fname}") == 0) return ${fname}_plugins(n);
`)
    }
    Content(`  (void)name;
  *n = 0;
  return NULL;
}
`)
  })
})


export {
  Config,
  FeaturePlugins,
  pluginDefinitions,
}
