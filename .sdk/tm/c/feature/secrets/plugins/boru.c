// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/boru.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* A boru vault, through its CLI or over its wire protocol.
 *
 * A plugin twice over: it spawns a child when it runs `boru`, and opens a
 * socket when an address and a capability token configure the wire form.
 *
 * A port of typescript/plugins/boru.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>

#include "support.h"

typedef struct {
  sek_pool *pool;
  const char *command;
  const char *namespace_;
  const char *home;
  char *addr;
  const char *token;
  const char *mount;
  char *described;
} borudata;

/* Does this boru failure mean "no such secret" rather than "I could not
 * answer"? Matched on boru's own wording for a missing alias. A locked
 * vault or a wrong passphrase is NOT a miss. */
static int borumiss(const char *why) { return sek_contains(why, "no alias named"); }

static sek_err boru_wire(borudata *data, const char *name, char **out) {
  sek_pool *pool = data->pool;
  sek_map *headers;
  sek_answer res;
  sek_err err = sek_checkaddr(pool, data->addr);
  char *url;
  const char *text;

  if (NULL != err) {
    return err;
  }

  /* The dotted name stays ONE path segment: a boru alias keeps its dots,
   * unlike the api/token split a HashiCorp KV gets. */
  if (sek_empty(data->namespace_)) {
    url = sek_fmt(pool, "%s/v1/%s/data/%s", data->addr, data->mount, name);
  } else {
    url = sek_fmt(pool, "%s/v1/%s/data/%s/%s", data->addr, data->mount, data->namespace_, name);
  }

  headers = sek_map_new(pool);
  sek_map_set(headers, "X-Vault-Token", sek_orempty(data->token));

  err = sek_fetchjson(pool, "GET", url, headers, NULL, &res);
  if (NULL != err) {
    return err;
  }

  if (404 == res.status) {
    return NULL;
  }

  if (200 != res.status) {
    return sek_fmt(pool, "sekreto: boru serve error: %d: %s", res.status, url);
  }

  text = sek_json_text(pool, sek_json_dig(res.body, "data", "data", "value", NULL));
  if (NULL != text) {
    *out = sek_strdup(pool, text);
  }

  return NULL;
}

static sek_err boru_lookup(sek_provider *self, const char *name, char **out) {
  borudata *data = (borudata *)self->data;
  sek_pool *pool = data->pool;
  sek_err err = sek_checkname(pool, name);
  char *alias;
  char *argv[6];
  sek_ran ran;
  size_t len;

  *out = NULL;

  if (NULL != err) {
    return err;
  }

  if (!sek_empty(data->addr)) {
    return boru_wire(data, name, out);
  }

  /* CLI mode: a COLON joins the namespace, not a slash. */
  alias = sek_empty(data->namespace_) ? sek_strdup(pool, name)
                                      : sek_fmt(pool, "%s:%s", data->namespace_, name);

  argv[0] = (char *)data->command;
  argv[1] = (char *)"vault";
  argv[2] = (char *)"get";
  argv[3] = (char *)"--reveal";
  argv[4] = alias;
  argv[5] = NULL;

  /* The passphrase is never config and never on a command line, where the
   * process table publishes it: boru reads BORU_VAULT_PASSPHRASE itself. */
  err = sek_runcmd(pool, argv, data->command, sek_empty(data->home) ? NULL : "BORU_HOME",
                   data->home, &ran);
  if (NULL != err) {
    return err;
  }

  if (0 == ran.status) {
    /* boru prints the value and one newline, and nothing else. */
    len = strlen(ran.out);
    *out = 1 <= len && '\n' == ran.out[len - 1] ? sek_strndup(pool, ran.out, len - 1) : ran.out;
    return NULL;
  }

  if (borumiss(ran.why)) {
    return NULL;
  }

  return sek_fmt(pool, "sekreto: boru vault error: %s",
                 sek_empty(ran.why) ? sek_fmt(pool, "exit %d", ran.status) : ran.why);
}

static const char *boru_describe(sek_provider *self) {
  return ((borudata *)self->data)->described;
}

/* ---- the definition ------------------------------------------------ */

static sek_err boru_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  borudata *data = (borudata *)sek_alloc(pool, sizeof(borudata));
  data->pool = pool;
  data->command = sek_own(pool, sek_empty(spec->command) ? "boru" : spec->command);
  data->namespace_ = sek_own(pool, spec->namespace_);
  data->home = sek_own(pool, spec->home);
  data->addr = NULL == spec->addr ? sek_strdup(pool, "") : sek_trimslash(pool, spec->addr);
  data->token = sek_own(pool, sek_orempty(spec->token));
  data->mount = sek_own(pool, sek_empty(spec->mount) ? "secret" : spec->mount);

  if (!sek_empty(data->addr)) {
    data->described = sek_fmt(pool, "boru:%s", data->addr);
  } else {
    data->described = sek_empty(data->namespace_)
                          ? sek_strdup(pool, "boru")
                          : sek_fmt(pool, "boru:%s", data->namespace_);
  }

  *out = sek_provider_new(pool, boru_lookup, boru_describe, data);
  return NULL;
}

static sek_providerkind BORU_KIND;

Definition *sek_plugin_boru(void) {
  return sek_providerplugin(&BORU_KIND, "boru", boru_make);
}
