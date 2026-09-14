// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/secretspec.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* SecretSpec, through its CLI.
 *
 * A plugin because it spawns a child. `proc.c` is the only object in the
 * library that forks, and only this kind and `boru` pull it into a link.
 *
 * A port of typescript/plugins/secretspec.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>

#include "support.h"

typedef struct {
  sek_pool *pool;
  const char *command;
  const char *file;
  const char *profile;
  const char *backend;
  const char *reason;
  const char *prefix;
  char *described;
} secretspecdata;

/* Does this SecretSpec failure mean "no such secret" rather than "I could
 * not answer"?
 *
 * MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
 * `Provider backend 'keyring' not found`, which is a store that could not
 * answer at all - and reading that as a miss is the worst failure this
 * library has, because the chain then falls through to a weaker store
 * without saying so. The key is required to appear, so the two cannot be
 * confused. */
static int secretspecmiss(sek_pool *pool, const char *why, const char *key) {
  return sek_contains(why, sek_fmt(pool, "Secret '%s' not found", key));
}

static sek_err secretspec_lookup(sek_provider *self, const char *name, char **out) {
  secretspecdata *data = (secretspecdata *)self->data;
  sek_pool *pool = data->pool;
  char *key = NULL;
  sek_err err = sek_envkey(pool, name, data->prefix, &key);
  char *argv[12];
  size_t at = 0;
  sek_ran ran;
  size_t len;

  *out = NULL;

  if (NULL != err) {
    return err;
  }

  /* The order is exact: --file comes BEFORE the subcommand, and --reason
   * is always sent, because SecretSpec audits every read and refuses
   * without one. */
  argv[at++] = (char *)data->command;
  if (!sek_empty(data->file)) {
    argv[at++] = (char *)"--file";
    argv[at++] = (char *)data->file;
  }
  argv[at++] = (char *)"get";
  argv[at++] = key;
  if (!sek_empty(data->backend)) {
    argv[at++] = (char *)"--provider";
    argv[at++] = (char *)data->backend;
  }
  if (!sek_empty(data->profile)) {
    argv[at++] = (char *)"--profile";
    argv[at++] = (char *)data->profile;
  }
  argv[at++] = (char *)"--reason";
  argv[at++] = (char *)sek_first(data->reason, "sekreto");
  argv[at] = NULL;

  err = sek_runcmd(pool, argv, data->command, NULL, NULL, &ran);
  if (NULL != err) {
    return err;
  }

  if (0 == ran.status) {
    len = strlen(ran.out);
    *out = 1 <= len && '\n' == ran.out[len - 1] ? sek_strndup(pool, ran.out, len - 1) : ran.out;
    return NULL;
  }

  if (secretspecmiss(pool, ran.why, key)) {
    return NULL;
  }

  return sek_fmt(pool, "sekreto: secretspec error: %s",
                 sek_empty(ran.why) ? sek_fmt(pool, "exit %d", ran.status) : ran.why);
}

static const char *secretspec_describe(sek_provider *self) {
  return ((secretspecdata *)self->data)->described;
}

/* ---- the definition ------------------------------------------------ */

static sek_err secretspec_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  secretspecdata *data = (secretspecdata *)sek_alloc(pool, sizeof(secretspecdata));
  data->pool = pool;
  data->command = sek_own(pool, sek_empty(spec->command) ? "secretspec" : spec->command);
  data->file = sek_own(pool, spec->file);
  data->profile = sek_own(pool, spec->profile);
  data->backend = sek_own(pool, spec->backend);
  data->reason = sek_own(pool, spec->reason);
  data->prefix = sek_own(pool, spec->prefix);
  data->described = sek_empty(spec->backend) ? sek_strdup(pool, "secretspec")
                                             : sek_fmt(pool, "secretspec:%s", spec->backend);
  *out = sek_provider_new(pool, secretspec_lookup, secretspec_describe, data);
  return NULL;
}

static sek_providerkind SECRETSPEC_KIND;

Definition *sek_plugin_secretspec(void) {
  return sek_providerplugin(&SECRETSPEC_KIND, "secretspec", secretspec_make);
}
