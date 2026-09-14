// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/azuresecrets.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Azure Key Vault, with client-credential or IMDS login.
 *
 * A plugin because it opens a socket. The percent-encoder its login form
 * needs is in `encode.c` with the transport, so this kind links no
 * SHA-256 either.
 *
 * A port of typescript/plugins/azuresecrets.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>

#include "support.h"

#define AZURE_RESOURCE "https://vault.azure.net"

typedef struct {
  sek_pool *pool;
  const char *vault;
  const char *token;
  const char *tenant;
  const char *clientid;
  const char *clientsecret;
  const char *loginaddr;
  const char *imdsaddr;
  const char *apiversion;
  char *livetoken;
  long long renewat;
  char *described;
} azuredata;

static sek_err azure_login(azuredata *data, char **out) {
  sek_pool *pool = data->pool;
  sek_map *headers;
  sek_answer res;
  sek_err err;
  const char *got;
  char *url;

  if (!sek_empty(data->token)) {
    *out = sek_strdup(pool, data->token);
    return NULL;
  }

  if (!sek_empty(data->tenant) && !sek_empty(data->clientid) && !sek_empty(data->clientsecret)) {
    const char *base = sek_first(data->loginaddr, "https://login.microsoftonline.com");
    char *form;

    err = sek_checkaddr(pool, base);
    if (NULL != err) {
      return err;
    }

    url = sek_fmt(pool, "%s/%s/oauth2/v2.0/token", sek_trimslash(pool, base), data->tenant);
    form = sek_fmt(pool, "grant_type=client_credentials&client_id=%s&client_secret=%s&scope=%s",
                   sek_uriescape(pool, data->clientid), sek_uriescape(pool, data->clientsecret),
                   sek_uriescape(pool, AZURE_RESOURCE "/.default"));

    headers = sek_map_new(pool);
    sek_map_set(headers, "content-type", "application/x-www-form-urlencoded");

    err = sek_fetchjson(pool, "POST", url, headers, form, &res);
    if (NULL != err) {
      return err;
    }

    got = sek_json_text(pool, sek_json_dig(res.body, "access_token", NULL));
    if (200 != res.status || sek_empty(got)) {
      return sek_fmt(pool, "sekreto: azure login failed: %d", res.status);
    }

    data->renewat = sek_renewtime(sek_json_dig(res.body, "expires_in", NULL));
    *out = sek_strdup(pool, got);
    return NULL;
  }

  /* IMDS: link-local by platform design, and it returns expires_in as a
   * STRING, which renewtime accepts. */
  url = sek_fmt(pool, "%s/metadata/identity/oauth2/token?api-version=2018-02-01&resource=%s",
                sek_trimslash(pool, sek_first(data->imdsaddr, "http://169.254.169.254")),
                sek_uriescape(pool, AZURE_RESOURCE));

  headers = sek_map_new(pool);
  sek_map_set(headers, "Metadata", "true");

  err = sek_fetchjson(pool, "GET", url, headers, NULL, &res);
  if (NULL != err) {
    return err;
  }

  got = sek_json_text(pool, sek_json_dig(res.body, "access_token", NULL));
  if (200 != res.status || sek_empty(got)) {
    return sek_strdup(pool,
                      "sekreto: azure: no token, no client credentials, and IMDS did not answer");
  }

  data->renewat = sek_renewtime(sek_json_dig(res.body, "expires_in", NULL));
  *out = sek_strdup(pool, got);

  return NULL;
}

static sek_err azure_lookup(sek_provider *self, const char *name, char **out) {
  azuredata *data = (azuredata *)self->data;
  sek_pool *pool = data->pool;
  char *vaulturl;
  char *flat = NULL;
  char *url;
  sek_map *headers;
  sek_answer res;
  sek_err err;
  const char *text;

  *out = NULL;

  if (sek_empty(data->vault)) {
    return sek_strdup(pool, "sekreto: azure: no vault");
  }

  /* ONLY an explicit scheme is a URL: a vault NAMED `httpvault` must
   * still become https://httpvault.vault.azure.net. */
  if (sek_has_prefix(data->vault, "http://") || sek_has_prefix(data->vault, "https://")) {
    vaulturl = sek_strdup(pool, data->vault);
  } else {
    vaulturl = sek_fmt(pool, "https://%s.vault.azure.net", data->vault);
  }

  err = sek_checkaddr(pool, vaulturl);
  if (NULL != err) {
    return err;
  }

  if (NULL == data->livetoken || sek_nowms() >= data->renewat) {
    err = azure_login(data, &data->livetoken);
    if (NULL != err) {
      return err;
    }
  }

  /* Dots flatten to `-`: Key Vault names allow letters, digits and
   * hyphens and nothing else. */
  err = sek_flatname(pool, name, "-", &flat);
  if (NULL != err) {
    return err;
  }

  url = sek_fmt(pool, "%s/secrets/%s?api-version=%s", sek_trimslash(pool, vaulturl), flat,
                sek_first(data->apiversion, "7.4"));

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
    return sek_fmt(pool, "sekreto: azure error: %d: %s", res.status, sek_bareurl(pool, url));
  }

  text = sek_json_text(pool, sek_json_dig(res.body, "value", NULL));
  if (NULL != text) {
    *out = sek_strdup(pool, text);
  }

  return NULL;
}

static const char *azure_describe(sek_provider *self) {
  return ((azuredata *)self->data)->described;
}

/* ---- the definition ------------------------------------------------ */

static sek_err azuresecrets_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  azuredata *data = (azuredata *)sek_alloc(pool, sizeof(azuredata));
  data->pool = pool;
  data->vault = sek_own(pool, spec->vault);
  data->token = sek_own(pool, spec->token);
  data->tenant = sek_own(pool, spec->tenant);
  data->clientid = sek_own(pool, spec->clientid);
  data->clientsecret = sek_own(pool, spec->clientsecret);
  data->loginaddr = sek_own(pool, spec->loginaddr);
  data->imdsaddr = sek_own(pool, spec->imdsaddr);
  data->apiversion = sek_own(pool, spec->apiversion);
  data->livetoken = NULL;
  data->renewat = SEK_NEVER;
  data->described = sek_fmt(pool, "azuresecrets:%s", sek_orempty(spec->vault));
  *out = sek_provider_new(pool, azure_lookup, azure_describe, data);
  return NULL;
}

static sek_providerkind AZURESECRETS_KIND;

Definition *sek_plugin_azuresecrets(void) {
  return sek_providerplugin(&AZURESECRETS_KIND, "azuresecrets", azuresecrets_make);
}
