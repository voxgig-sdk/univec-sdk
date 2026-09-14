// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/gcpsecrets.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Google Secret Manager, with metadata-server login.
 *
 * A plugin because it opens a socket. The base64 it decodes a payload
 * with lives in `encode.c` with the transport, not with the signer, so
 * this kind links no SHA-256.
 *
 * A port of typescript/plugins/gcpsecrets.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>

#include "support.h"

typedef struct {
  sek_pool *pool;
  const char *project;
  const char *token;
  const char *addr;
  const char *metadataaddr;
  char *livetoken;
  long long renewat;
  char *described;
} gcpdata;

static sek_err gcp_login(gcpdata *data, char **out) {
  sek_pool *pool = data->pool;
  const char *configured = sek_first(data->token, getenv("GOOGLE_OAUTH_ACCESS_TOKEN"));
  const char *base;
  char *url;
  sek_map *headers;
  sek_answer res;
  sek_err err;
  const char *got;

  if (!sek_empty(configured)) {
    *out = sek_strdup(pool, configured);
    return NULL;
  }

  if (!sek_empty(data->metadataaddr)) {
    base = data->metadataaddr;
  } else {
    const char *host = getenv("GCE_METADATA_HOST");
    base = sek_empty(host) ? "http://metadata.google.internal" : sek_fmt(pool, "http://%s", host);
  }

  url = sek_fmt(pool, "%s/computeMetadata/v1/instance/service-accounts/default/token",
                sek_trimslash(pool, base));

  headers = sek_map_new(pool);
  sek_map_set(headers, "Metadata-Flavor", "Google");

  /* The metadata call is plain http to a link-local host by platform
   * design and carries no credential, so it is deliberately NOT
   * checkaddr-guarded; the Secret Manager address is. */
  err = sek_fetchjson(pool, "GET", url, headers, NULL, &res);
  if (NULL != err) {
    return err;
  }

  got = sek_json_text(pool, sek_json_dig(res.body, "access_token", NULL));
  if (200 != res.status || sek_empty(got)) {
    return sek_strdup(pool, "sekreto: gcp: no token and metadata server did not answer");
  }

  data->renewat = sek_renewtime(sek_json_dig(res.body, "expires_in", NULL));
  *out = sek_strdup(pool, got);

  return NULL;
}

static sek_err gcp_lookup(sek_provider *self, const char *name, char **out) {
  gcpdata *data = (gcpdata *)self->data;
  sek_pool *pool = data->pool;
  const char *addr;
  char *flat = NULL;
  char *url;
  sek_map *headers;
  sek_answer res;
  sek_err err;
  const char *encoded;

  *out = NULL;

  if (sek_empty(data->project)) {
    return sek_strdup(pool, "sekreto: gcp: no project");
  }

  addr = sek_first(data->addr, "https://secretmanager.googleapis.com");
  err = sek_checkaddr(pool, addr);
  if (NULL != err) {
    return err;
  }

  if (NULL == data->livetoken || sek_nowms() >= data->renewat) {
    err = gcp_login(data, &data->livetoken);
    if (NULL != err) {
      return err;
    }
  }

  /* Dots flatten to `_`: Secret Manager ids have no hierarchy and reject
   * dots. */
  err = sek_flatname(pool, name, "_", &flat);
  if (NULL != err) {
    return err;
  }

  url = sek_fmt(pool, "%s/v1/projects/%s/secrets/%s/versions/latest:access",
                sek_trimslash(pool, addr), data->project, flat);

  headers = sek_map_new(pool);
  sek_map_set(headers, "authorization", sek_fmt(pool, "Bearer %s", sek_orempty(data->livetoken)));

  err = sek_fetchjson(pool, "GET", url, headers, NULL, &res);
  if (NULL != err) {
    return err;
  }

  if (404 == res.status) {
    return NULL;
  }

  if (200 != res.status) {
    return sek_fmt(pool, "sekreto: gcp error: %d: %s", res.status, url);
  }

  encoded = sek_json_asstr(sek_json_dig(res.body, "payload", "data", NULL));
  if (NULL == encoded) {
    return NULL;
  }

  {
    size_t len = 0;
    unsigned char *raw = sek_unbase64(pool, encoded, &len);

    if (NULL == raw) {
      return sek_strdup(pool, "sekreto: gcp: undecodable secret");
    }

    *out = sek_strndup(pool, (const char *)raw, len);
  }

  return NULL;
}

static const char *gcp_describe(sek_provider *self) {
  return ((gcpdata *)self->data)->described;
}

/* ---- the definition ------------------------------------------------ */

static sek_err gcpsecrets_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  gcpdata *data = (gcpdata *)sek_alloc(pool, sizeof(gcpdata));
  data->pool = pool;
  data->project = sek_own(pool, spec->project);
  data->token = sek_own(pool, spec->token);
  data->addr = sek_own(pool, spec->addr);
  data->metadataaddr = sek_own(pool, spec->metadataaddr);
  data->livetoken = NULL;
  data->renewat = SEK_NEVER;
  data->described = sek_fmt(pool, "gcpsecrets:%s", sek_orempty(spec->project));
  *out = sek_provider_new(pool, gcp_lookup, gcp_describe, data);
  return NULL;
}

static sek_providerkind GCPSECRETS_KIND;

Definition *sek_plugin_gcpsecrets(void) {
  return sek_providerplugin(&GCPSECRETS_KIND, "gcpsecrets", gcpsecrets_make);
}
