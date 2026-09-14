// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/aws.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* AWS Secrets Manager and SSM Parameter Store: two kinds, one file.
 *
 * They share the credential resolution and the SigV4 signing, which is
 * the reason they are one translation unit rather than two - splitting
 * them would put the signer in both links or in neither.
 *
 * THE ONLY KINDS IN THE LIBRARY THAT HASH ANYTHING. `sigv4.c` and the
 * `sha256.c` under it are pulled into a link by this object and by
 * nothing else; a chain of the other nine plugins carries no digest at
 * all, and `make check-core` measures that rather than asserting it.
 *
 * A port of typescript/plugins/aws.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>

#include "support.h"

typedef struct {
  sek_pool *pool;
  const char *region;
  const char *keyid;
  const char *secret;
  const char *session;
  const char *addr;
  const char *prefix;
  char *described;
} awsdata;

/* Region and credentials, from config first and the standard AWS_*
 * environment variables second - those are AWS's own convention, and a
 * pod or CI job that has them set should just work. Missing either is an
 * error: an AWS store with no credentials could not answer. */
static sek_err awscall(awsdata *data, const char *service, const char *targetname,
                       const char *payload, sek_answer *out) {
  sek_pool *pool = data->pool;
  const char *region = sek_first3(data->region, getenv("AWS_REGION"), getenv("AWS_DEFAULT_REGION"));
  const char *keyid = sek_first(data->keyid, getenv("AWS_ACCESS_KEY_ID"));
  const char *secret = sek_first(data->secret, getenv("AWS_SECRET_ACCESS_KEY"));
  const char *session = sek_first(data->session, getenv("AWS_SESSION_TOKEN"));
  const char *addr;
  char *url;
  sek_map *extras;
  sek_map *signed_;
  sek_signing input;
  sek_err err;
  size_t index;

  if (sek_empty(region)) {
    return sek_strdup(pool, "sekreto: aws: no region (set region or AWS_REGION)");
  }
  if (sek_empty(keyid) || sek_empty(secret)) {
    return sek_strdup(pool, "sekreto: aws: no credentials (set keyid/secret or "
                            "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)");
  }

  /* The China partition lives under its own suffix; every other
   * commercial region is plain amazonaws.com. */
  addr = sek_first(data->addr, sek_fmt(pool, "https://%s.%s%s", service, region,
                                       sek_has_prefix(region, "cn-") ? ".amazonaws.com.cn"
                                                                     : ".amazonaws.com"));

  err = sek_checkaddr(pool, addr);
  if (NULL != err) {
    return err;
  }

  url = sek_fmt(pool, "%s/", sek_trimslash(pool, addr));

  extras = sek_map_new(pool);
  sek_map_set(extras, "content-type", "application/x-amz-json-1.1");
  sek_map_set(extras, "x-amz-target", targetname);

  memset(&input, 0, sizeof(input));
  input.method = "POST";
  input.url = url;
  input.service = service;
  input.region = region;
  input.keyid = keyid;
  input.secret = secret;
  input.datetime = sek_awsnow(pool);
  input.headers = extras;
  input.body = payload;
  input.session = sek_empty(session) ? NULL : session;

  signed_ = sek_sigv4(pool, &input);

  /* The signed headers go on top of the caller's. */
  for (index = 0; index < signed_->len; index++) {
    sek_map_set(extras, signed_->keys[index], signed_->vals[index]);
  }

  return sek_fetchjson(pool, "POST", url, extras, payload, out);
}

/* Does this AWS error body name the not-found type? AWS sends it fully
 * qualified - `com.amazonaws...#ResourceNotFoundException` - so this is a
 * containment test, and it is only ever consulted alongside a 400. */
static int awsmiss(sek_json *body, const char *type) {
  const char *errtype = sek_json_asstr(sek_json_dig(body, "__type", NULL));

  return NULL != errtype && sek_contains(errtype, type);
}

static sek_err awssecrets_lookup(sek_provider *self, const char *name, char **out) {
  awsdata *data = (awsdata *)self->data;
  sek_pool *pool = data->pool;
  sek_vaultref ref;
  sek_json *payload;
  sek_answer res;
  sek_err err;
  const char *text;

  *out = NULL;

  err = sek_vaultref_of(pool, name, &ref);
  if (NULL != err) {
    return err;
  }

  payload = sek_json_obj(pool);
  sek_json_set(pool, payload, "SecretId", sek_json_str(pool, ref.path));

  err = awscall(data, "secretsmanager", "secretsmanager.GetSecretValue",
                sek_json_stringify(pool, payload), &res);
  if (NULL != err) {
    return err;
  }

  if (400 == res.status && awsmiss(res.body, "ResourceNotFoundException")) {
    return NULL;
  }

  if (200 != res.status) {
    return sek_fmt(pool, "sekreto: aws secretsmanager error: %d", res.status);
  }

  text = sek_json_asstr(sek_json_dig(res.body, "SecretString", NULL));

  if (NULL == text) {
    /* A binary secret has no fields to address, so only the conventional
     * `value` field can mean "the bytes themselves". */
    const char *bin = sek_json_asstr(sek_json_dig(res.body, "SecretBinary", NULL));

    if (NULL != bin && 0 == strcmp(ref.field, "value")) {
      size_t len = 0;
      unsigned char *raw = sek_unbase64(pool, bin, &len);

      if (NULL == raw) {
        return sek_strdup(pool, "sekreto: aws secretsmanager: undecodable secret");
      }

      *out = sek_strndup(pool, (const char *)raw, len);
      return NULL;
    }

    return NULL;
  }

  {
    /* The AWS idiom is one JSON map per secret, so the secret's own value
     * is parsed and the field taken out of it. */
    sek_json *parsed = sek_json_parse(pool, text);

    if (NULL != parsed && SEK_JSON_OBJ == parsed->type) {
      const char *found = sek_json_text(pool, sek_json_dig(parsed, ref.field, NULL));
      if (NULL != found) {
        *out = sek_strdup(pool, found);
      }
      return NULL;
    }
  }

  /* A plain-string secret is the whole value; it has no named fields. */
  if (0 == strcmp(ref.field, "value")) {
    *out = sek_strdup(pool, text);
  }

  return NULL;
}

static sek_err awsparams_lookup(sek_provider *self, const char *name, char **out) {
  awsdata *data = (awsdata *)self->data;
  sek_pool *pool = data->pool;
  char *param = NULL;
  sek_json *payload;
  sek_answer res;
  sek_err err = sek_awsparam(pool, name, data->prefix, &param);
  const char *text;

  *out = NULL;

  if (NULL != err) {
    return err;
  }

  payload = sek_json_obj(pool);
  sek_json_set(pool, payload, "Name", sek_json_str(pool, param));
  sek_json_set(pool, payload, "WithDecryption", sek_json_bool(pool, 1));

  err = awscall(data, "ssm", "AmazonSSM.GetParameter", sek_json_stringify(pool, payload), &res);
  if (NULL != err) {
    return err;
  }

  if (400 == res.status && awsmiss(res.body, "ParameterNotFound")) {
    return NULL;
  }

  if (200 != res.status) {
    return sek_fmt(pool, "sekreto: aws ssm error: %d", res.status);
  }

  /* Parameter Store carries flat strings: no field indirection. */
  text = sek_json_text(pool, sek_json_dig(res.body, "Parameter", "Value", NULL));
  if (NULL != text) {
    *out = sek_strdup(pool, text);
  }

  return NULL;
}

static const char *aws_describe(sek_provider *self) {
  return ((awsdata *)self->data)->described;
}

/* ---- the definitions ----------------------------------------------- */

/* One `make` for both kinds, taking the half that differs as an argument.
 * They share every field of the spec and every byte of the signing; only
 * the lookup and the description differ. */
static sek_err aws_make(sek_pool *pool, const sek_spec *spec, int params, sek_provider **out) {
  awsdata *data = (awsdata *)sek_alloc(pool, sizeof(awsdata));

  data->pool = pool;
  data->region = sek_own(pool, spec->region);
  data->keyid = sek_own(pool, spec->keyid);
  data->secret = sek_own(pool, spec->secret);
  data->session = sek_own(pool, spec->session);
  data->addr = sek_own(pool, spec->addr);
  data->prefix = sek_own(pool, spec->prefix);

  /* Config only, never the environment: describe() feeds the spec's
   * sources group, which must answer the same everywhere. */
  if (params) {
    data->described =
        sek_fmt(pool, "awsparams:%s%s", sek_orempty(spec->region), sek_orempty(spec->prefix));
  } else {
    data->described = sek_fmt(pool, "awssecrets:%s", sek_orempty(spec->region));
  }

  *out = sek_provider_new(pool, params ? awsparams_lookup : awssecrets_lookup, aws_describe, data);

  return NULL;
}

static sek_err awssecrets_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  return aws_make(pool, spec, 0, out);
}

static sek_err awsparams_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  return aws_make(pool, spec, 1, out);
}

static sek_providerkind AWSSECRETS_KIND;

Definition *sek_plugin_awssecrets(void) {
  return sek_providerplugin(&AWSSECRETS_KIND, "awssecrets", awssecrets_make);
}

static sek_providerkind AWSPARAMS_KIND;

Definition *sek_plugin_awsparams(void) {
  return sek_providerplugin(&AWSPARAMS_KIND, "awsparams", awsparams_make);
}
