// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/doppler.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Doppler.
 *
 * A plugin because it opens a socket.
 *
 * A port of typescript/plugins/doppler.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>

#include "support.h"

typedef struct {
  sek_pool *pool;
  const char *token;
  const char *project;
  const char *config;
  const char *addr;
  sek_map *values;
  char *described;
} dopplerdata;

/* The whole config is downloaded ONCE - Doppler's own bulk endpoint - and
 * answered from memory, like a remote .env. A failure caches nothing, so
 * a failed load retries on the next lookup. */
static sek_err doppler_load(dopplerdata *data) {
  sek_pool *pool = data->pool;
  char *addr;
  sek_buf url;
  sek_map *headers;
  sek_answer res;
  sek_err err;
  const sek_json *body;
  sek_map *loaded;
  size_t index;

  if (NULL != data->values) {
    return NULL;
  }

  addr = sek_trimslash(pool, sek_first(data->addr, "https://api.doppler.com"));
  err = sek_checkaddr(pool, addr);
  if (NULL != err) {
    return err;
  }

  sek_buf_init(&url, pool);
  sek_buf_addfmt(&url, "%s/v3/configs/config/secrets/download?format=json", addr);
  if (!sek_empty(data->project)) {
    sek_buf_addfmt(&url, "&project=%s", sek_uriescape(pool, data->project));
  }
  if (!sek_empty(data->config)) {
    sek_buf_addfmt(&url, "&config=%s", sek_uriescape(pool, data->config));
  }

  headers = sek_map_new(pool);
  sek_map_set(headers, "authorization", sek_fmt(pool, "Bearer %s", sek_orempty(data->token)));

  err = sek_fetchjson(pool, "GET", url.data, headers, NULL, &res);
  if (NULL != err) {
    return err;
  }

  body = sek_json_asobj(res.body);
  if (200 != res.status || NULL == body) {
    return sek_fmt(pool, "sekreto: doppler error: %d", res.status);
  }

  loaded = sek_map_new(pool);
  for (index = 0; index < body->maplen; index++) {
    /* Entries with null values are skipped; the rest are stringified. */
    const char *text = sek_json_text(pool, body->vals[index]);
    if (NULL != text) {
      sek_map_set(loaded, body->keys[index], text);
    }
  }

  data->values = loaded;

  return NULL;
}

static sek_err doppler_lookup(sek_provider *self, const char *name, char **out) {
  dopplerdata *data = (dopplerdata *)self->data;
  sek_pool *pool = data->pool;
  char *key = NULL;
  sek_err err;
  const char *found;

  *out = NULL;

  /* The `prefix` option is deliberately not consulted by this kind. */
  err = sek_envkey(pool, name, NULL, &key);
  if (NULL != err) {
    return err;
  }

  err = doppler_load(data);
  if (NULL != err) {
    return err;
  }

  found = sek_map_get(data->values, key);
  if (NULL != found) {
    *out = sek_strdup(pool, found);
  }

  return NULL;
}

static const char *doppler_describe(sek_provider *self) {
  return ((dopplerdata *)self->data)->described;
}

/* ---- the definition ------------------------------------------------ */

static sek_err doppler_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  dopplerdata *data = (dopplerdata *)sek_alloc(pool, sizeof(dopplerdata));
  data->pool = pool;
  data->token = sek_own(pool, spec->token);
  data->project = sek_own(pool, spec->project);
  data->config = sek_own(pool, spec->config);
  data->addr = sek_own(pool, spec->addr);
  data->values = NULL;
  data->described = sek_empty(spec->project)
                        ? sek_strdup(pool, "doppler")
                        : sek_fmt(pool, "doppler:%s/%s", spec->project, sek_orempty(spec->config));
  *out = sek_provider_new(pool, doppler_lookup, doppler_describe, data);
  return NULL;
}

static sek_providerkind DOPPLER_KIND;

Definition *sek_plugin_doppler(void) {
  return sek_providerplugin(&DOPPLER_KIND, "doppler", doppler_make);
}
