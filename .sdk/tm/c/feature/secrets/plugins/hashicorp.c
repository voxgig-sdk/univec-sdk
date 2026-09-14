// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/hashicorp.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* HashiCorp Vault, over its HTTP API.
 *
 * KV v1 and v2, a configured token or a login (kubernetes, approle, jwt),
 * and Vault Enterprise namespaces. A plugin because it opens a socket:
 * `sekreto: unknown provider kind: hashicorp` is what a chain naming it
 * gets when the consumer did not pass this definition in.
 *
 * A port of typescript/plugins/hashicorp.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "support.h"

typedef struct {
  sek_pool *pool;
  const char *addr;
  const char *mount;
  int kv;
  const char *vaultnamespace;
  sek_authspec *auth;
  char *livetoken;
  long long renewat;
  char *described;
} hashicorpdata;

static sek_map *vaultheaders(hashicorpdata *data) {
  sek_map *out = sek_map_new(data->pool);

  /* A Vault Enterprise namespace rides the header on LOGINS as well as
   * reads: a login to the wrong namespace fails in a way that reads like
   * a bad credential. */
  if (!sek_empty(data->vaultnamespace)) {
    sek_map_set(out, "X-Vault-Namespace", data->vaultnamespace);
  }

  return out;
}

static sek_err hashicorp_login(hashicorpdata *data, char **out) {
  sek_pool *pool = data->pool;
  sek_authspec *use = data->auth;
  char *url;
  sek_json *payload;
  sek_answer res;
  sek_err err;
  const char *got;

  if (NULL == use) {
    return sek_strdup(pool, "sekreto: hashicorp: no token and no auth method");
  }

  url = sek_fmt(pool, "%s/v1/auth/%s/login", sek_trimslash(pool, data->addr),
                sek_first(use->mount, use->method));

  if (NULL != use->method && 0 == strcmp(use->method, "kubernetes")) {
    const char *jwt = use->jwt;

    if (sek_empty(jwt)) {
      const char *path = sek_empty(use->jwtfile)
                             ? "/var/run/secrets/kubernetes.io/serviceaccount/token"
                             : use->jwtfile;
      int why = 0;
      char *text = sek_readfile(pool, path, &why);

      if (NULL == text) {
        /* No underlying error text: the path is what a reader needs, and
         * the strerror string follows the machine's locale. */
        return sek_fmt(pool, "sekreto: hashicorp: cannot read jwt file %s", path);
      }

      {
        size_t start = 0;
        size_t end = strlen(text);
        while (start < end && (' ' == text[start] || '\n' == text[start] || '\r' == text[start] ||
                               '\t' == text[start])) {
          start++;
        }
        while (end > start && (' ' == text[end - 1] || '\n' == text[end - 1] ||
                               '\r' == text[end - 1] || '\t' == text[end - 1])) {
          end--;
        }
        jwt = sek_strndup(pool, text + start, end - start);
      }
    }

    payload = sek_json_obj(pool);
    sek_json_set(pool, payload, "role", sek_json_str(pool, sek_orempty(use->role)));
    sek_json_set(pool, payload, "jwt", sek_json_str(pool, jwt));
  } else if (NULL != use->method && 0 == strcmp(use->method, "approle")) {
    payload = sek_json_obj(pool);
    sek_json_set(pool, payload, "role_id", sek_json_str(pool, sek_orempty(use->roleid)));
    sek_json_set(pool, payload, "secret_id", sek_json_str(pool, sek_orempty(use->secretid)));
  } else {
    return sek_fmt(pool, "sekreto: hashicorp: unknown auth method: %s", sek_orempty(use->method));
  }

  err = sek_fetchjson(pool, "POST", url, vaultheaders(data), sek_json_stringify(pool, payload),
                      &res);
  if (NULL != err) {
    return err;
  }

  got = sek_json_text(pool, sek_json_dig(res.body, "auth", "client_token", NULL));

  /* A failed login is an ERROR, never a miss: it means this store could
   * not answer at all. */
  if (200 != res.status || sek_empty(got)) {
    return sek_fmt(pool, "sekreto: hashicorp login failed: %d: %s", res.status, url);
  }

  data->renewat = sek_renewtime(sek_json_dig(res.body, "auth", "lease_duration", NULL));
  *out = sek_strdup(pool, got);

  return NULL;
}

static sek_err hashicorp_lookup(sek_provider *self, const char *name, char **out) {
  hashicorpdata *data = (hashicorpdata *)self->data;
  sek_pool *pool = data->pool;
  sek_vaultref ref;
  sek_map *headers;
  sek_answer res;
  sek_err err;
  char *url;
  sek_json *found;

  *out = NULL;

  err = sek_checkaddr(pool, data->addr);
  if (NULL != err) {
    return err;
  }

  if (NULL == data->livetoken || sek_nowms() >= data->renewat) {
    err = hashicorp_login(data, &data->livetoken);
    if (NULL != err) {
      return err;
    }
  }

  err = sek_vaultref_of(pool, name, &ref);
  if (NULL != err) {
    return err;
  }

  if (1 == data->kv) {
    url = sek_fmt(pool, "%s/v1/%s/%s", sek_trimslash(pool, data->addr), data->mount, ref.path);
  } else {
    url = sek_fmt(pool, "%s/v1/%s/data/%s", sek_trimslash(pool, data->addr), data->mount, ref.path);
  }

  headers = vaultheaders(data);
  sek_map_set(headers, "X-Vault-Token", sek_orempty(data->livetoken));

  err = sek_fetchjson(pool, "GET", url, headers, NULL, &res);
  if (NULL != err) {
    return err;
  }

  /* A 404 means "not here" - a miss - so a vault can sit in a chain with
   * fallbacks behind it. */
  if (404 == res.status) {
    return NULL;
  }

  if (200 != res.status) {
    return sek_fmt(pool, "sekreto: hashicorp error: %d: %s", res.status, url);
  }

  if (1 == data->kv) {
    found = sek_json_dig(res.body, "data", ref.field, NULL);
  } else {
    found = sek_json_dig(res.body, "data", "data", ref.field, NULL);
  }

  {
    const char *text = sek_json_text(pool, found);
    if (NULL != text) {
      *out = sek_strdup(pool, text);
    }
  }

  return NULL;
}

static const char *hashicorp_describe(sek_provider *self) {
  return ((hashicorpdata *)self->data)->described;
}

/* ---- the definition ------------------------------------------------ */

static sek_err hashicorp_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  hashicorpdata *data = (hashicorpdata *)sek_alloc(pool, sizeof(hashicorpdata));
  data->pool = pool;
  data->addr = sek_own(pool, sek_orempty(spec->addr));
  data->mount = sek_own(pool, sek_empty(spec->mount) ? "secret" : spec->mount);
  data->kv = spec->haskv ? spec->kv : 2;
  data->vaultnamespace = sek_own(pool, spec->vaultnamespace);
  data->livetoken = sek_empty(spec->token) ? NULL : sek_strdup(pool, spec->token);
  data->renewat = SEK_NEVER;
  data->described = sek_fmt(pool, "hashicorp:%s/%s", data->addr, data->mount);

  if (NULL != spec->auth) {
    data->auth = (sek_authspec *)sek_alloc(pool, sizeof(sek_authspec));
    data->auth->method = sek_own(pool, spec->auth->method);
    data->auth->mount = sek_own(pool, spec->auth->mount);
    data->auth->role = sek_own(pool, spec->auth->role);
    data->auth->jwt = sek_own(pool, spec->auth->jwt);
    data->auth->jwtfile = sek_own(pool, spec->auth->jwtfile);
    data->auth->roleid = sek_own(pool, spec->auth->roleid);
    data->auth->secretid = sek_own(pool, spec->auth->secretid);
  } else {
    data->auth = NULL;
  }

  /* A version typo like `kv: 3` must not quietly behave as v2 and turn
   * its 404s into misses; there is nothing safe to assume it meant. So
   * it is refused at CONSTRUCTION, before an address is even looked at. */
  if (1 != data->kv && 2 != data->kv) {
    return sek_fmt(pool, "sekreto: hashicorp: unsupported kv version: %d", data->kv);
  }

  *out = sek_provider_new(pool, hashicorp_lookup, hashicorp_describe, data);
  return NULL;
}

static sek_providerkind HASHICORP_KIND;

Definition *sek_plugin_hashicorp(void) {
  return sek_providerplugin(&HASHICORP_KIND, "hashicorp", hashicorp_make);
}
