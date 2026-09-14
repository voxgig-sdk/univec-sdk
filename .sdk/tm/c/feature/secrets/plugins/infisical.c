// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/infisical.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Infisical, with universal-auth login.
 *
 * A plugin because it opens a socket.
 *
 * A port of typescript/plugins/infisical.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>

#include "support.h"

typedef struct {
  sek_pool *pool;
  const char *addr;
  const char *token;
  const char *clientid;
  const char *clientsecret;
  const char *project;
  const char *environment;
  const char *path;
  char *livetoken;
  long long renewat;
  char *described;
} infisicaldata;

static sek_err infisical_login(infisicaldata *data, const char *addr, char **out) {
  sek_pool *pool = data->pool;
  sek_json *payload;
  sek_map *headers;
  sek_answer res;
  sek_err err;
  const char *got;

  if (!sek_empty(data->token)) {
    *out = sek_strdup(pool, data->token);
    return NULL;
  }

  if (sek_empty(data->clientid) || sek_empty(data->clientsecret)) {
    return sek_strdup(pool, "sekreto: infisical: no token and no client credentials");
  }

  payload = sek_json_obj(pool);
  sek_json_set(pool, payload, "clientId", sek_json_str(pool, data->clientid));
  sek_json_set(pool, payload, "clientSecret", sek_json_str(pool, data->clientsecret));

  headers = sek_map_new(pool);
  sek_map_set(headers, "content-type", "application/json");

  err = sek_fetchjson(pool, "POST", sek_fmt(pool, "%s/api/v1/auth/universal-auth/login", addr),
                      headers, sek_json_stringify(pool, payload), &res);
  if (NULL != err) {
    return err;
  }

  got = sek_json_text(pool, sek_json_dig(res.body, "accessToken", NULL));
  if (200 != res.status || sek_empty(got)) {
    return sek_fmt(pool, "sekreto: infisical login failed: %d", res.status);
  }

  /* camelCase, unlike everyone else's expires_in. */
  data->renewat = sek_renewtime(sek_json_dig(res.body, "expiresIn", NULL));
  *out = sek_strdup(pool, got);

  return NULL;
}

static sek_err infisical_lookup(sek_provider *self, const char *name, char **out) {
  infisicaldata *data = (infisicaldata *)self->data;
  sek_pool *pool = data->pool;
  char *addr = sek_trimslash(pool, sek_first(data->addr, "https://app.infisical.com"));
  char *key = NULL;
  char *url;
  sek_map *headers;
  sek_answer res;
  sek_err err = sek_checkaddr(pool, addr);
  const char *text;

  *out = NULL;

  if (NULL != err) {
    return err;
  }

  if (sek_empty(data->project) || sek_empty(data->environment)) {
    return sek_strdup(pool, "sekreto: infisical: no project/environment");
  }

  if (NULL == data->livetoken || sek_nowms() >= data->renewat) {
    err = infisical_login(data, addr, &data->livetoken);
    if (NULL != err) {
      return err;
    }
  }

  /* envkey here takes NO prefix: Infisical's own convention is plain
   * environment-style keys. */
  err = sek_envkey(pool, name, NULL, &key);
  if (NULL != err) {
    return err;
  }

  url = sek_fmt(pool, "%s/api/v3/secrets/raw/%s?workspaceId=%s&environment=%s&secretPath=%s", addr,
                key, sek_uriescape(pool, data->project), sek_uriescape(pool, data->environment),
                sek_uriescape(pool, sek_first(data->path, "/")));

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
    return sek_fmt(pool, "sekreto: infisical error: %d", res.status);
  }

  text = sek_json_text(pool, sek_json_dig(res.body, "secret", "secretValue", NULL));
  if (NULL != text) {
    *out = sek_strdup(pool, text);
  }

  return NULL;
}

static const char *infisical_describe(sek_provider *self) {
  return ((infisicaldata *)self->data)->described;
}

/* ---- the definition ------------------------------------------------ */

static sek_err infisical_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  infisicaldata *data = (infisicaldata *)sek_alloc(pool, sizeof(infisicaldata));
  data->pool = pool;
  data->addr = sek_own(pool, spec->addr);
  data->token = sek_own(pool, spec->token);
  data->clientid = sek_own(pool, spec->clientid);
  data->clientsecret = sek_own(pool, spec->clientsecret);
  data->project = sek_own(pool, spec->project);
  data->environment = sek_own(pool, spec->environment);
  data->path = sek_own(pool, spec->path);
  data->livetoken = NULL;
  data->renewat = SEK_NEVER;
  data->described = sek_fmt(pool, "infisical:%s/%s", sek_orempty(spec->project),
                            sek_orempty(spec->environment));
  *out = sek_provider_new(pool, infisical_lookup, infisical_describe, data);
  return NULL;
}

static sek_providerkind INFISICAL_KIND;

Definition *sek_plugin_infisical(void) {
  return sek_providerplugin(&INFISICAL_KIND, "infisical", infisical_make);
}
