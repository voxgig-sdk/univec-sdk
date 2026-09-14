// Generated: the plugin definitions the model selected for the `secrets`
// feature's provider chain (the c peer of go's core.FeaturePlugins), read
// back by core/config.c's feature_plugins("secrets", &n).
//
// GENERATED beside kinds.mk, the build wiring tm/c/Makefile includes. Do
// not hand-edit - change the model's plugin groups and regenerate.

#include "sdk.h"

#include "sekreto.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// One prototype per selected kind: the `Definition *(void)` constructor
// its vendored file defines (plugins/sekretoplugins.h declares all ten;
// naming only these keeps the link line the boundary upstream intends).
Definition* sek_plugin_boru(void);
Definition* sek_plugin_hashicorp(void);

static void* SECRETS_KINDS[2];

void** secrets_plugins(size_t* n) {
  SECRETS_KINDS[0] = sek_plugin_boru();
  SECRETS_KINDS[1] = sek_plugin_hashicorp();
  *n = 2;
  return SECRETS_KINDS;
}

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
  b->data[b->len] = '\0';
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
  if (NULL == method || '\0' == method[0]) method = "POST";

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
    snprintf(msg, sizeof(msg), "secrets: token exchange transport failed: %s (URL was: \"%s\")",
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
