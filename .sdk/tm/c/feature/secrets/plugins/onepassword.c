// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/onepassword.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* 1Password Connect.
 *
 * A plugin because it opens a socket.
 *
 * A port of typescript/plugins/onepassword.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>

#include "support.h"

typedef struct {
  sek_pool *pool;
  const char *addr;
  const char *token;
  const char *vault;
  char *vaultid;
  char *described;
} onepassworddata;

static sek_map *opauth(onepassworddata *data) {
  sek_map *out = sek_map_new(data->pool);

  sek_map_set(out, "authorization", sek_fmt(data->pool, "Bearer %s", sek_orempty(data->token)));

  return out;
}

/* The vault id, resolved once and memoised. A vault that cannot be found
 * is an ERROR, not a miss: config names it, so its absence is a broken
 * store rather than a missing secret. */
static sek_err opvault(onepassworddata *data, const char *addr, char **out) {
  sek_pool *pool = data->pool;
  sek_answer res;
  sek_err err;
  const sek_json *list;
  size_t index;

  if (sek_empty(data->vault)) {
    return sek_strdup(pool, "sekreto: onepassword: no vault");
  }

  err = sek_fetchjson(pool, "GET", sek_fmt(pool, "%s/v1/vaults", addr), opauth(data), NULL, &res);
  if (NULL != err) {
    return err;
  }

  list = sek_json_asarr(res.body);
  if (200 != res.status || NULL == list) {
    return sek_fmt(pool, "sekreto: onepassword error: %d: listing vaults", res.status);
  }

  for (index = 0; index < list->itemlen; index++) {
    const char *id = sek_json_text(pool, sek_json_dig(list->items[index], "id", NULL));
    const char *label = sek_json_text(pool, sek_json_dig(list->items[index], "name", NULL));

    if ((NULL != id && 0 == strcmp(data->vault, id)) ||
        (NULL != label && 0 == strcmp(data->vault, label))) {
      *out = sek_strdup(pool, sek_orempty(id));
      return NULL;
    }
  }

  return sek_fmt(pool, "sekreto: onepassword: no vault named %s", data->vault);
}

static sek_err onepassword_lookup(sek_provider *self, const char *name, char **out) {
  onepassworddata *data = (onepassworddata *)self->data;
  sek_pool *pool = data->pool;
  sek_err err = sek_checkname(pool, name);
  char *addr;
  sek_answer found;
  sek_answer item;
  const sek_json *items;
  const sek_json *fields;
  size_t index;

  *out = NULL;

  if (NULL != err) {
    return err;
  }

  addr = sek_trimslash(pool, sek_orempty(data->addr));
  if (sek_empty(addr)) {
    return sek_strdup(pool, "sekreto: onepassword: no addr");
  }

  err = sek_checkaddr(pool, addr);
  if (NULL != err) {
    return err;
  }

  if (NULL == data->vaultid) {
    err = opvault(data, addr, &data->vaultid);
    if (NULL != err) {
      return err;
    }
  }

  /* Item titles keep their dots. */
  err = sek_fetchjson(
      pool, "GET",
      sek_fmt(pool, "%s/v1/vaults/%s/items?filter=%s", addr, data->vaultid,
              sek_uriescape(pool, sek_fmt(pool, "title eq \"%s\"", name))),
      opauth(data), NULL, &found);
  if (NULL != err) {
    return err;
  }

  items = sek_json_asarr(found.body);
  if (200 != found.status || NULL == items) {
    return sek_fmt(pool, "sekreto: onepassword error: %d: finding %s", found.status, name);
  }

  /* An empty list is the secret not being there: a miss. */
  if (0 == items->itemlen) {
    return NULL;
  }

  err = sek_fetchjson(pool, "GET",
                      sek_fmt(pool, "%s/v1/vaults/%s/items/%s", addr, data->vaultid,
                              sek_orempty(sek_json_text(pool, sek_json_dig(items->items[0], "id",
                                                                          NULL)))),
                      opauth(data), NULL, &item);
  if (NULL != err) {
    return err;
  }

  if (200 != item.status) {
    return sek_fmt(pool, "sekreto: onepassword error: %d: reading %s", item.status, name);
  }

  fields = sek_json_asarr(sek_json_dig(item.body, "fields", NULL));
  if (NULL == fields) {
    return NULL;
  }

  /* Two full passes, in this order: the password field first, then a
   * field labelled `value`. */
  for (index = 0; index < fields->itemlen; index++) {
    const char *purpose = sek_json_asstr(sek_json_dig(fields->items[index], "purpose", NULL));
    if (NULL != purpose && 0 == strcmp(purpose, "PASSWORD")) {
      const char *value = sek_json_text(pool, sek_json_dig(fields->items[index], "value", NULL));
      if (NULL != value) {
        *out = sek_strdup(pool, value);
      }
      return NULL;
    }
  }

  for (index = 0; index < fields->itemlen; index++) {
    const char *label = sek_json_asstr(sek_json_dig(fields->items[index], "label", NULL));
    if (NULL != label && 0 == strcmp(label, "value")) {
      const char *value = sek_json_text(pool, sek_json_dig(fields->items[index], "value", NULL));
      if (NULL != value) {
        *out = sek_strdup(pool, value);
      }
      return NULL;
    }
  }

  return NULL;
}

static const char *onepassword_describe(sek_provider *self) {
  return ((onepassworddata *)self->data)->described;
}

/* ---- the definition ------------------------------------------------ */

static sek_err onepassword_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  onepassworddata *data = (onepassworddata *)sek_alloc(pool, sizeof(onepassworddata));
  data->pool = pool;
  data->addr = sek_own(pool, spec->addr);
  data->token = sek_own(pool, spec->token);
  data->vault = sek_own(pool, spec->vault);
  data->vaultid = NULL;
  data->described = sek_fmt(pool, "onepassword:%s", sek_orempty(spec->vault));
  *out = sek_provider_new(pool, onepassword_lookup, onepassword_describe, data);
  return NULL;
}

static sek_providerkind ONEPASSWORD_KIND;

Definition *sek_plugin_onepassword(void) {
  return sek_providerplugin(&ONEPASSWORD_KIND, "onepassword", onepassword_make);
}
