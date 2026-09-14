// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/src/providers.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* What a provider is, what its declarative form looks like, how a provider
 * kind becomes a voxgig/plugin definition - and the four BUILT-IN kinds.
 *
 * A provider answers one question: "do you have this secret?" It returns
 * the value, or a miss to mean "ask the next one". Nothing else about a
 * provider is visible to the caller - which is the point: an app reads
 * `api.token` and never learns whether it came from the environment, a
 * .env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.
 *
 * TWO FAILURE SHAPES, AND THEY ARE NEVER INTERCHANGEABLE. A store that
 * does not hold the secret is a MISS (`*out = NULL`, no error) and the
 * chain carries on. A store that could not answer - bad credentials,
 * unreachable host, missing configuration - is an ERROR: falling through
 * there would quietly reach for a weaker store.
 *
 * THIS FILE NAMES NO SOCKET, NO CHILD PROCESS AND NO HASH FUNCTION. What
 * makes a kind built in is that it needs nothing of the platform beyond
 * the environment and reading a local file; every kind that opens a
 * socket, signs a request or spawns a process is a plugin under
 * `plugins/`, in its own translation unit, linked only by a binary whose
 * link line names it (docs/design/plugin-providers.md).
 *
 * A port of typescript/src/provider/support.ts and
 * typescript/src/provider/builtin.ts, which are canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

/* ---- spec ---------------------------------------------------------- */

sek_spec sek_spec_new(const char *kind) {
  sek_spec spec;

  memset(&spec, 0, sizeof(spec));
  spec.kind = kind;

  return spec;
}

/* What a credential field reports about itself: whether it is set, never
 * what it is. */
static const char *setornot(const char *value) { return sek_empty(value) ? "[unset]" : "[set]"; }

char *sek_authspec_show(sek_pool *pool, const sek_authspec *auth) {
  if (NULL == auth) {
    return sek_strdup(pool, "(none)");
  }

  return sek_fmt(pool,
                 "AuthSpec(method=%s, mount=%s, role=%s, jwtfile=%s, roleid=%s, jwt=%s, "
                 "secretid=%s)",
                 sek_orempty(auth->method), sek_orempty(auth->mount), sek_orempty(auth->role),
                 sek_orempty(auth->jwtfile), sek_orempty(auth->roleid), setornot(auth->jwt),
                 setornot(auth->secretid));
}

/* Printed without its credentials. The obvious debug print of a chain
 * that will not build - which is exactly what someone writes when a chain
 * will not build - would otherwise put the Vault token, the AWS secret
 * access key and the Azure client secret wherever it was printed. */
char *sek_spec_show(sek_pool *pool, const sek_spec *spec) {
  return sek_fmt(pool,
                 "ProviderSpec(kind=%s, name=%s, addr=%s, token=%s, secret=%s, clientsecret=%s, "
                 "auth=%s)",
                 sek_orempty(spec->kind), sek_orempty(spec->name), sek_orempty(spec->addr),
                 setornot(spec->token), setornot(spec->secret), setornot(spec->clientsecret),
                 sek_authspec_show(pool, spec->auth));
}

/* ---- addresses ----------------------------------------------------- */

/* Every refusal below names the address it refused, and one of them fires
 * precisely because the address carries a credential - so printing it
 * verbatim would write that password to stderr and into the logs. It
 * cannot be cleaned up afterwards either: that password was never
 * resolved as a secret, so redact() has never seen it and never will. */
char *sek_safeaddr(sek_pool *pool, const char *addr) {
  const char *mark = strstr(addr, "://");
  const char *rest;
  const char *stop;
  char *authority;
  const char *at;
  size_t head;

  if (NULL == mark) {
    return sek_strdup(pool, addr);
  }

  rest = mark + 3;
  stop = rest;
  while ('\0' != *stop && '/' != *stop && '?' != *stop && '#' != *stop) {
    stop++;
  }

  authority = sek_strndup(pool, rest, (size_t)(stop - rest));
  at = strrchr(authority, '@');

  if (NULL == at) {
    return sek_strdup(pool, addr);
  }

  head = (size_t)(rest - addr);

  return sek_fmt(pool, "%.*s[redacted]%s", (int)head, addr, rest + (size_t)(at - authority));
}

/* Refuse to send a secret-bearing credential in the clear.
 *
 * A vault API is HTTPS in any real deployment; plaintext is a dev-mode
 * convenience. Sending a token over http to anything but the local
 * machine puts both the token and the secret it fetches on the wire for
 * anyone on the path, so sekreto will not do it. Loopback stays allowed:
 * that is `vault server -dev`, `boru vault serve` and this repository's
 * own test harness.
 *
 * The address is read BY HAND, in the same handful of steps in every
 * port, rather than by a platform URL parser. Twelve parsers disagree
 * about malformed input - where userinfo ends, whether `0177.0.0.1` is
 * loopback, what an unclosed bracket means - and a check that answers
 * differently in different ports is not a check.
 *
 * The rule this parse obeys, and the reason it can be trusted: it is
 * never MORE PERMISSIVE than the HTTP client that will dial the address.
 * It ends the authority at `/`, `?` or `#` only, so a client that also
 * breaks on `\` can only ever see a SHORTER host than this does. It
 * refuses userinfo outright rather than locating its end. It compares the
 * host literally, so a numeric form no parser agrees on is refused rather
 * than guessed at. */
sek_err sek_checkaddr(sek_pool *pool, const char *addr) {
  const char *rest;
  const char *stop;
  char *authority;
  char *host;
  int tls;

  if (NULL == addr) {
    addr = "";
  }

  /* A literal, case-sensitive prefix. `HTTP://localhost` is refused. */
  if (sek_has_prefix(addr, "https://")) {
    rest = addr + 8;
    tls = 1;
  } else if (sek_has_prefix(addr, "http://")) {
    rest = addr + 7;
    tls = 0;
  } else {
    return sek_fmt(pool, "sekreto: not an http(s) address: %s", sek_safeaddr(pool, addr));
  }

  stop = rest;
  while ('\0' != *stop && '/' != *stop && '?' != *stop && '#' != *stop) {
    stop++;
  }
  authority = sek_strndup(pool, rest, (size_t)(stop - rest));

  /* Userinfo is refused outright rather than parsed around, and on https
   * as well as http. No store this library speaks authenticates by
   * userinfo - they take a token or a signature - so an address carrying
   * one is a mistake at best. At worst it is the attack this whole
   * function exists to stop: `http://localhost:8200@evil.example.com/` is
   * a request to evil.example.com that reads, to anything splitting the
   * authority on ':', as loopback. */
  if (NULL != strchr(authority, '@')) {
    return sek_fmt(pool, "sekreto: refusing an address with embedded credentials: %s",
                   sek_safeaddr(pool, addr));
  }

  /* An opening bracket with no closing one is not an address at all. */
  if ('[' == authority[0] && NULL == strchr(authority, ']')) {
    return sek_fmt(pool, "sekreto: not a valid http(s) address: %s", sek_safeaddr(pool, addr));
  }

  if (tls) {
    return NULL;
  }

  /* A bracketed IPv6 literal keeps its brackets. Splitting the authority
   * on the first colon yields `[`, so `http://[::1]:8200` could never
   * match the allowlist below - which refuses a legitimate local vault. */
  if ('[' == authority[0]) {
    const char *close = strchr(authority, ']');
    host = sek_strndup(pool, authority, (size_t)(close - authority) + 1);
  } else {
    const char *colon = strchr(authority, ':');
    host = NULL == colon ? sek_strdup(pool, authority)
                         : sek_strndup(pool, authority, (size_t)(colon - authority));
  }
  host = sek_lowercase(pool, host);

  /* Literal, and exactly four entries. Nothing is normalised:
   * `0177.0.0.1`, `2130706433`, `127.0.0.2` and `[::ffff:127.0.0.1]` are
   * all refused, because no two URL parsers agree on what they mean. */
  if (0 == strcmp(host, "localhost") || 0 == strcmp(host, "127.0.0.1") ||
      0 == strcmp(host, "::1") || 0 == strcmp(host, "[::1]")) {
    return NULL;
  }

  return sek_fmt(pool, "sekreto: refusing to send a token in plaintext to %s (use https)",
                 sek_safeaddr(pool, addr));
}

/* ---- the four built-in kinds --------------------------------------- */

/* `env`, `memory`, `dotenv` and `file`: the floor every chain stands on.
 * A chain of these works with no plugin loaded at all, which is the
 * property the whole split exists to give a consumer.
 *
 * Each is the same shape as a plugin - a lookup, a describe, and a `make`
 * that a voxgig/plugin definition calls - so there is one mechanism here
 * and not two. */

/* ---- env ----------------------------------------------------------- */

typedef struct {
  sek_pool *pool;
  const char *prefix;
  char *described;
} envdata;

static sek_err env_lookup(sek_provider *self, const char *name, char **out) {
  envdata *data = (envdata *)self->data;
  char *key = NULL;
  sek_err err = sek_envkey(data->pool, name, data->prefix, &key);
  const char *found;

  *out = NULL;

  if (NULL != err) {
    return err;
  }

  found = getenv(key);
  if (NULL != found) {
    *out = sek_strdup(data->pool, found);
  }

  return NULL;
}

static const char *env_describe(sek_provider *self) {
  return ((envdata *)self->data)->described;
}

/* ---- memory -------------------------------------------------------- */

typedef struct {
  sek_pool *pool;
  sek_map *values;
  const char *prefix;
  char *described;
} memorydata;

static sek_err memory_lookup(sek_provider *self, const char *name, char **out) {
  memorydata *data = (memorydata *)self->data;
  char *key = NULL;
  sek_err err = sek_envkey(data->pool, name, data->prefix, &key);
  const char *found;

  *out = NULL;

  if (NULL != err) {
    return err;
  }

  /* An absent key is a miss and the empty string is a HIT, so this asks
   * the map rather than reading a value and testing it for emptiness. */
  found = sek_map_get(data->values, key);
  if (NULL != found) {
    *out = sek_strdup(data->pool, found);
  }

  return NULL;
}

static const char *memory_describe(sek_provider *self) {
  return ((memorydata *)self->data)->described;
}

/* ---- dotenv -------------------------------------------------------- */

typedef struct {
  sek_pool *pool;
  const char *file;
  const char *prefix;
  sek_map *values; /* NULL until the first lookup */
  char *described;
} dotenvdata;

/* Read once, LAZILY, and memoised. Lazily because the `stores` corpus
 * group puts a dotenv provider in a chain and never looks anything up: an
 * eager constructor would read whatever .env happened to sit in the
 * test's working directory. */
static sek_err dotenv_load(dotenvdata *data) {
  char *text;
  int why = 0;

  if (NULL != data->values) {
    return NULL;
  }

  text = sek_readfile(data->pool, data->file, &why);

  if (NULL == text) {
    if (sek_absent(why)) {
      /* No file, or no directory: "no secrets here", not a failure. */
      data->values = sek_map_new(data->pool);
      return NULL;
    }
    return sek_fmt(data->pool, "sekreto: dotenv provider cannot read %s: %s", data->file,
                   strerror(why));
  }

  data->values = sek_parsedotenv(data->pool, text);

  return NULL;
}

static sek_err dotenv_lookup(sek_provider *self, const char *name, char **out) {
  dotenvdata *data = (dotenvdata *)self->data;
  char *key = NULL;
  sek_err err;
  const char *found;

  *out = NULL;

  err = sek_envkey(data->pool, name, data->prefix, &key);
  if (NULL != err) {
    return err;
  }

  err = dotenv_load(data);
  if (NULL != err) {
    return err;
  }

  found = sek_map_get(data->values, key);
  if (NULL != found) {
    *out = sek_strdup(data->pool, found);
  }

  return NULL;
}

static const char *dotenv_describe(sek_provider *self) {
  return ((dotenvdata *)self->data)->described;
}

/* ---- file ---------------------------------------------------------- */

typedef struct {
  sek_pool *pool;
  const char *dir;
  const char *prefix;
  char *described;
} filedata;

/* One secret per file, keyed like the environment: `api.token` reads
 * `<dir>/API_TOKEN`. This is the shape of a mounted Kubernetes Secret, a
 * Docker or Swarm secret, and a systemd credentials directory, so those
 * all work with no further configuration. Read on EVERY lookup, with no
 * caching: a rotated secret is a rewritten file. */
static sek_err file_lookup(sek_provider *self, const char *name, char **out) {
  filedata *data = (filedata *)self->data;
  char *key = NULL;
  sek_err err = sek_envkey(data->pool, name, data->prefix, &key);
  char *path;
  char *text;
  size_t len;
  int why = 0;

  *out = NULL;

  if (NULL != err) {
    return err;
  }

  path = sek_empty(data->dir) ? key : sek_fmt(data->pool, "%s/%s", data->dir, key);

  text = sek_readfile(data->pool, path, &why);

  if (NULL == text) {
    if (sek_absent(why)) {
      return NULL;
    }
    /* The JOINED path, not the directory: that is what could not be
     * read. */
    return sek_fmt(data->pool, "sekreto: file provider cannot read %s: %s", path, strerror(why));
  }

  /* Exactly one trailing newline, `\r\n` before `\n`, and only at the
   * end. Tools that write these files disagree about it, and a newline is
   * never part of a secret on purpose - one left on turns a bearer header
   * into a malformed one. */
  len = strlen(text);
  if (2 <= len && '\r' == text[len - 2] && '\n' == text[len - 1]) {
    text = sek_strndup(data->pool, text, len - 2);
  } else if (1 <= len && '\n' == text[len - 1]) {
    text = sek_strndup(data->pool, text, len - 1);
  }

  *out = text;

  return NULL;
}

static const char *file_describe(sek_provider *self) {
  return ((filedata *)self->data)->described;
}


/* ---- a spec, as a plugin instance's options ------------------------ */

/* The spec's own key names - the ones the shared spec and a config file
 * use - paired with where each lands in a sek_spec.
 *
 * A TABLE RATHER THAN THIRTY LINES EACH WAY, because the two directions
 * must not drift: a field written but not read is a store configured with
 * a value it never sees, and the conformance suite only notices for the
 * handful of fields its chains set. Every string field is here; `values`,
 * `kv` and `auth` are not strings and are handled below. */
typedef struct {
  const char *key;
  size_t at;
} strfield;

#define SEK_FIELD(name, member) {name, offsetof(sek_spec, member)}
#define SEK_FIELD_AUTH(name, member) {name, offsetof(sek_authspec, member)}

static const strfield STRFIELDS[] = {
    SEK_FIELD("kind", kind),
    SEK_FIELD("name", name),
    SEK_FIELD("prefix", prefix),
    SEK_FIELD("file", file),
    SEK_FIELD("dir", dir),
    SEK_FIELD("addr", addr),
    SEK_FIELD("token", token),
    SEK_FIELD("mount", mount),
    SEK_FIELD("vaultnamespace", vaultnamespace),
    SEK_FIELD("command", command),
    SEK_FIELD("profile", profile),
    SEK_FIELD("backend", backend),
    SEK_FIELD("reason", reason),
    /* `namespace` is a keyword in C++ and several of the ports, so the C
     * struct spells it `namespace_`; the wire key is the spec's. */
    SEK_FIELD("namespace", namespace_),
    SEK_FIELD("home", home),
    SEK_FIELD("region", region),
    SEK_FIELD("keyid", keyid),
    SEK_FIELD("secret", secret),
    SEK_FIELD("session", session),
    SEK_FIELD("project", project),
    SEK_FIELD("vault", vault),
    SEK_FIELD("tenant", tenant),
    SEK_FIELD("clientid", clientid),
    SEK_FIELD("clientsecret", clientsecret),
    SEK_FIELD("loginaddr", loginaddr),
    SEK_FIELD("imdsaddr", imdsaddr),
    SEK_FIELD("metadataaddr", metadataaddr),
    SEK_FIELD("apiversion", apiversion),
    SEK_FIELD("config", config),
    SEK_FIELD("environment", environment),
    SEK_FIELD("path", path),
};

static const strfield AUTHFIELDS[] = {
    SEK_FIELD_AUTH("method", method),   SEK_FIELD_AUTH("mount", mount),
    SEK_FIELD_AUTH("role", role),       SEK_FIELD_AUTH("jwt", jwt),
    SEK_FIELD_AUTH("jwtfile", jwtfile), SEK_FIELD_AUTH("roleid", roleid),
    SEK_FIELD_AUTH("secretid", secretid),
};

static const char **fieldof(sek_spec *spec, size_t at) {
  return (const char **)((char *)spec + at);
}

static const char *const *readfield(const sek_spec *spec, size_t at) {
  return (const char *const *)((const char *)spec + at);
}

static const char **authfieldof(sek_authspec *auth, size_t at) {
  return (const char **)((char *)auth + at);
}

static const char *const *readauth(const sek_authspec *auth, size_t at) {
  return (const char *const *)((const char *)auth + at);
}

/* A spec as the options map its plugin instance is declared with.
 *
 * Only fields that are SET are written, so an instance's options read
 * like the chain entry that produced them. An empty string is set: it
 * means the same as unset everywhere in this library, but round-tripping
 * it unchanged is what keeps the two directions honest. */
Value *sek_optionsof(const sek_spec *spec) {
  Value *options = vmap();
  size_t index;

  for (index = 0; index < sizeof(STRFIELDS) / sizeof(STRFIELDS[0]); index++) {
    const char *value = *readfield(spec, STRFIELDS[index].at);
    if (NULL != value) {
      vset(options, STRFIELDS[index].key, vstr(value));
    }
  }

  if (NULL != spec->values) {
    Value *values = vmap();
    size_t at;
    for (at = 0; at < spec->values->len; at++) {
      vset(values, spec->values->keys[at], vstr(spec->values->vals[at]));
    }
    vset(options, "values", values);
  }

  if (spec->haskv) {
    vset(options, "kv", vnum(spec->kv));
  }

  if (NULL != spec->auth) {
    Value *auth = vmap();
    for (index = 0; index < sizeof(AUTHFIELDS) / sizeof(AUTHFIELDS[0]); index++) {
      const char *value = *readauth(spec->auth, AUTHFIELDS[index].at);
      if (NULL != value) {
        vset(auth, AUTHFIELDS[index].key, vstr(value));
      }
    }
    vset(options, "auth", auth);
  }

  return options;
}

/* ...and back, as the kind's `define` reads it.
 *
 * Every string is copied into the pool. The options map lives in
 * voxgig/plugin's arena, which this library never resets and therefore
 * never frees; copying keeps the ownership rule this header states - a
 * provider's strings come from the pool it was built with - true anyway,
 * rather than true by accident. */
static sek_spec specof(sek_pool *pool, Value *options) {
  sek_spec spec = sek_spec_new(NULL);
  Value *values = vget(options, "values");
  Value *kv = vget(options, "kv");
  Value *auth = vget(options, "auth");
  size_t index;

  for (index = 0; index < sizeof(STRFIELDS) / sizeof(STRFIELDS[0]); index++) {
    Value *held = vget(options, STRFIELDS[index].key);
    if (visstr(held)) {
      *fieldof(&spec, STRFIELDS[index].at) = sek_strdup(pool, vasstr(held));
    }
  }

  if (vismap(values)) {
    const char **keys;
    size_t count = vkeys(values, &keys);
    size_t at;
    spec.values = sek_map_new(pool);
    for (at = 0; at < count; at++) {
      Value *held = vget(values, keys[at]);
      sek_map_set(spec.values, keys[at], visstr(held) ? vasstr(held) : vjson(held));
    }
  }

  if (visnum(kv)) {
    spec.kv = (int)vasnum(kv);
    spec.haskv = 1;
  }

  if (vismap(auth)) {
    sek_authspec *use = (sek_authspec *)sek_alloc(pool, sizeof(sek_authspec));
    for (index = 0; index < sizeof(AUTHFIELDS) / sizeof(AUTHFIELDS[0]); index++) {
      Value *held = vget(auth, AUTHFIELDS[index].key);
      if (visstr(held)) {
        *authfieldof(use, AUTHFIELDS[index].at) = sek_strdup(pool, vasstr(held));
      }
    }
    spec.auth = use;
  }

  return spec;
}

/* ---- the bridge ---------------------------------------------------- */

/* WHAT `define` NEEDS AND A voxgig/plugin Definition CANNOT CARRY.
 *
 * plugin's value model holds numbers and strings, never pointers, and a
 * Definition is data with function pointers in it and no context. So the
 * pool a provider is allocated from, and the providers themselves, travel
 * through this file-scope slot for the duration of one sek_new - the same
 * shape the zig port uses, and the shape plugin's own C port uses for its
 * pending error. A definition exports the INDEX of the provider it built
 * and sek_new reads it back.
 *
 * The port claims no thread safety across constructions, and says so on
 * sek_new. Nothing here is touched after sek_new returns. */
typedef struct {
  sek_pool *pool;
  sek_provider **built;
  size_t len;
  size_t cap;
} building;

static building SLOT;
static building *BUILDING = NULL;

void sek_build_begin(sek_pool *pool) {
  memset(&SLOT, 0, sizeof(SLOT));
  SLOT.pool = pool;
  BUILDING = &SLOT;
}

void sek_build_end(void) { BUILDING = NULL; }

/* The provider a definition exported, by the index it exported. Answers
 * NULL for an index no `define` of this construction handed out, which is
 * how a Definition that is not a provider plugin at all is caught.
 *
 * THE RANGE IS CHECKED AS A DOUBLE, BEFORE THE CAST. An export is a plugin
 * number, so a hand-written definition may put any double under the export
 * key, and converting one that does not fit a size_t is undefined - on
 * x86-64 gcc it wraps, and 1e30 came back as index 0, which is a live
 * provider of this construction rather than the NULL this function
 * promises. Written as `!(index < len)` rather than `index >= len` so that
 * a NaN, which compares false with everything, is refused as well. */
sek_provider *sek_build_at(double index) {
  if (NULL == BUILDING || !(0 <= index) || !(index < (double)BUILDING->len)) {
    return NULL;
  }

  return BUILDING->built[(size_t)index];
}

static double keep(sek_provider *provider) {
  if (BUILDING->len == BUILDING->cap) {
    size_t cap = 0 == BUILDING->cap ? 8 : BUILDING->cap * 2;
    sek_provider **bigger =
        (sek_provider **)sek_alloc(BUILDING->pool, cap * sizeof(sek_provider *));
    /* Guarded: the first growth copies from a NULL `built`, and memcpy's
     * source is declared never-null even for a length of zero. */
    if (0 < BUILDING->len) {
      memcpy(bigger, BUILDING->built, BUILDING->len * sizeof(sek_provider *));
    }
    BUILDING->built = bigger;
    BUILDING->cap = cap;
  }

  BUILDING->built[BUILDING->len] = provider;

  return (double)BUILDING->len++;
}

/* The one `define` every provider kind shares.
 *
 * It finds its own kind's `make` by asking the host's catalog for the
 * definition registered under this instance's name and casting it back to
 * the sek_providerkind it is the first member of. That is why `def` must
 * stay first, and it is what makes a plugin a data structure rather than
 * a generated function per kind. A Definition that is NOT one of ours
 * never reaches here - it has its own `define`, or none - and sek_new
 * refuses it by name when it exports no provider. */
static void provider_define(Inst *inst) {
  Definition *def = catalog_get(host_catalog(inst_host(inst)), inst_name(inst));
  sek_providerkind *kind = (sek_providerkind *)def;
  sek_provider *made = NULL;
  sek_spec spec;
  sek_err err;

  spec = specof(BUILDING->pool, inst_options(inst));

  err = kind->make(BUILDING->pool, &spec, &made);

  /* A refusal crosses the boundary under sekreto's own code, carrying the
   * message as `cause`, and sek_new turns it back into a sek_err. The
   * shared spec pins these byte for byte, so the host must not rewrite
   * them - and it does not: plugin keeps an error that already has a
   * code, and only wraps a code-less one as plugin_define_failed. */
  if (NULL != err) {
    fail(SEK_ERROR_CODE, err, details2("ref", vstr(inst_ref(inst)), "cause", vstr(err)));
  }

  inst_export(inst, SEK_PROVIDER_EXPORT, vnum(keep(made)));
}

Definition *sek_providerplugin(sek_providerkind *slot, const char *kind, sek_makefn make) {
  memset(slot, 0, sizeof(*slot));

  slot->def.name = kind;
  slot->def.define = provider_define;
  slot->make = make;

  return &slot->def;
}

/* ---- the built-in kinds, as definitions ---------------------------- */

/* A spec string, copied into the pool: a spec is the caller's and may be
 * a stack value that is gone by the first lookup.
 *
 * Not static, and neither is the one below it: every plugin's `make` is
 * written against the same two, so a kind under `plugins/` is built
 * exactly the way a built-in is. */
const char *sek_own(sek_pool *pool, const char *text) {
  return NULL == text ? NULL : sek_strdup(pool, text);
}

sek_provider *sek_provider_new(sek_pool *pool,
                               sek_err (*lookup)(sek_provider *, const char *, char **),
                               const char *(*describe)(sek_provider *), void *data) {
  sek_provider *out = (sek_provider *)sek_alloc(pool, sizeof(sek_provider));

  out->lookup = lookup;
  out->describe = describe;
  out->data = data;
  out->pool = pool;

  return out;
}

static sek_err env_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  envdata *data = (envdata *)sek_alloc(pool, sizeof(envdata));

  data->pool = pool;
  data->prefix = sek_own(pool, spec->prefix);
  data->described =
      sek_empty(spec->prefix) ? sek_strdup(pool, "env") : sek_fmt(pool, "env:%s", spec->prefix);

  *out = sek_provider_new(pool, env_lookup, env_describe, data);

  return NULL;
}

static sek_err memory_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  memorydata *data = (memorydata *)sek_alloc(pool, sizeof(memorydata));

  data->pool = pool;
  data->prefix = sek_own(pool, spec->prefix);
  data->values = sek_map_new(pool);
  if (NULL != spec->values) {
    size_t index;
    for (index = 0; index < spec->values->len; index++) {
      sek_map_set(data->values, spec->values->keys[index], spec->values->vals[index]);
    }
  }
  data->described = sek_empty(spec->prefix) ? sek_strdup(pool, "memory")
                                            : sek_fmt(pool, "memory:%s", spec->prefix);

  *out = sek_provider_new(pool, memory_lookup, memory_describe, data);

  return NULL;
}

static sek_err dotenv_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  dotenvdata *data = (dotenvdata *)sek_alloc(pool, sizeof(dotenvdata));

  data->pool = pool;
  data->file = sek_own(pool, sek_empty(spec->file) ? ".env" : spec->file);
  data->prefix = sek_own(pool, spec->prefix);
  data->values = NULL;
  data->described = sek_fmt(pool, "dotenv:%s", data->file);

  *out = sek_provider_new(pool, dotenv_lookup, dotenv_describe, data);

  return NULL;
}

static sek_err file_make(sek_pool *pool, const sek_spec *spec, sek_provider **out) {
  filedata *data = (filedata *)sek_alloc(pool, sizeof(filedata));

  data->pool = pool;
  data->dir = sek_own(pool, sek_orempty(spec->dir));
  data->prefix = sek_own(pool, spec->prefix);
  data->described = sek_fmt(pool, "file:%s", data->dir);

  *out = sek_provider_new(pool, file_lookup, file_describe, data);

  return NULL;
}

/* The four, as definitions, in the order sek_new puts them in a catalog.
 * File-scope storage rather than a pool allocation: a definition is code
 * plus a name, the same for every Sekreto in the process, and nothing
 * here is written after the first call. */
static sek_providerkind BUILTINKINDS[4];
static Definition *BUILTINDEFS[4];

size_t sek_builtins(Definition ***out) {
  BUILTINDEFS[0] = sek_providerplugin(&BUILTINKINDS[0], "env", env_make);
  BUILTINDEFS[1] = sek_providerplugin(&BUILTINKINDS[1], "memory", memory_make);
  BUILTINDEFS[2] = sek_providerplugin(&BUILTINKINDS[2], "dotenv", dotenv_make);
  BUILTINDEFS[3] = sek_providerplugin(&BUILTINKINDS[3], "file", file_make);

  *out = BUILTINDEFS;

  return 4;
}

const char *const SEK_BUILTIN_KINDS[] = {"env", "memory", "dotenv", "file", NULL};

const char *const SEK_PLUGIN_KINDS[] = {
    "hashicorp", "boru",        "awssecrets", "awsparams", "gcpsecrets",
    "azuresecrets", "onepassword", "doppler",  "infisical", "secretspec", NULL};
