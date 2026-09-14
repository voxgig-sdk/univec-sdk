// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/src/sekreto.h)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* sekreto: one interface for secrets, wherever they live.
 *
 * A Sekreto is an ordered chain of providers. `get` asks each in turn and
 * returns the first hit, so an app can be configured from environment
 * variables in development and a vault in production without changing a
 * line of its own code.
 *
 * A port of typescript/src/Sekreto.ts, which is canonical.
 *
 * THIS IS THE CORE, AND IT HOLDS FOUR PROVIDER KINDS: `env`, `memory`,
 * `dotenv` and `file`. What makes a kind built in is that it reads at
 * most a local file. Every kind that opens a socket, signs a request or
 * spawns a child - the vault clients, the cloud stores, the two CLIs,
 * and SigV4 signing with them - is a voxgig/plugin definition under
 * `plugins/`, and a Sekreto can build only the kinds its options were
 * handed. Nothing in `src/` names anything under `plugins/`; the
 * link line is the boundary, and `make check-core` is the proof
 * (docs/design/plugin-providers.md).
 *
 * Two conventions run through this header, and everything else follows
 * from them.
 *
 * OWNERSHIP. Every allocation comes from a sek_pool and is freed in one
 * go by sek_pool_free. Nothing returned by this library is freed by the
 * caller, and nothing returned outlives the pool it came from. A Sekreto
 * borrows the pool it is built with; sek_close releases its chain but not
 * the pool.
 *
 * FAILURE. C has no exceptions, so a fallible call returns `sek_err` - a
 * pool-owned message, or NULL for success - and writes its result through
 * an out-parameter. A MISS is not a failure: a lookup that succeeds with
 * `*out == NULL` means "this store does not hold it", and the chain
 * carries on. Collapsing the two would make a chain fall silently through
 * to a weaker store, which is the worst failure this library has.
 */

#ifndef VOXGIG_SEKRETO_H
#define VOXGIG_SEKRETO_H

#include <stddef.h>

/* voxgig/plugin, the one library sekreto depends on. C has no package
 * manager, so a consumer compiles with its source directory on the
 * include path - the Makefile finds the checkout the way it finds omni.
 * `host.h` pulls in `catalog.h`, `types.h`, `value.h` and `point.h`
 * with it; `ref.h` is the name+tag grammar a store name has to satisfy. */
#include "host.h"
#include "ref.h"

/* An error message, or NULL when the call succeeded. Pool-owned. */
typedef const char *sek_err;

/* ---- pool ---------------------------------------------------------- */

typedef struct sek_pool sek_pool;

sek_pool *sek_pool_new(void);

/* Releases everything the pool handed out.
 *
 * IT DOES NOT TOUCH voxgig/plugin's ARENA, and that is deliberate rather
 * than an omission. plugin's C port allocates every Value from one
 * process-global arena freed all at once by `arena_reset`, so resetting
 * it on behalf of one pool would free the instance options and exported
 * values of every OTHER live Sekreto in the process. The declarations a
 * chain makes are therefore held until the process exits: a few hundred
 * bytes per configured provider, on an application's startup path. A
 * process that builds chains without end, and knows it holds none, may
 * call `arena_reset` itself. */
void sek_pool_free(sek_pool *pool);

/* Zeroed memory from the pool. Never returns NULL: an arena that cannot
 * grow is a process that cannot continue, and a library that answers a
 * secret request with a half-filled buffer is worse than one that stops. */
void *sek_alloc(sek_pool *pool, size_t size);
char *sek_strdup(sek_pool *pool, const char *text);
char *sek_strndup(sek_pool *pool, const char *text, size_t len);

/* printf into the pool. */
char *sek_fmt(sek_pool *pool, const char *fmt, ...);

/* ---- buffer -------------------------------------------------------- */

/* A growable byte buffer. `data` is always NUL-terminated, so a buffer of
 * text is a C string the moment it is needed as one, while `len` stays
 * authoritative for a body that may carry embedded NULs. */
typedef struct {
  sek_pool *pool;
  char *data;
  size_t len;
  size_t cap;
} sek_buf;

void sek_buf_init(sek_buf *buf, sek_pool *pool);
void sek_buf_add(sek_buf *buf, const char *text);
void sek_buf_addn(sek_buf *buf, const char *text, size_t len);
void sek_buf_addch(sek_buf *buf, char ch);
void sek_buf_addfmt(sek_buf *buf, const char *fmt, ...);

/* ---- ordered string map -------------------------------------------- */

/* Insertion-ordered, because the spec compares whole maps and an AWS
 * payload's field order is signed. A list of pairs, not a hash: these are
 * never big enough for the difference to matter. */
typedef struct {
  sek_pool *pool;
  char **keys;
  char **vals;
  size_t len;
  size_t cap;
} sek_map;

sek_map *sek_map_new(sek_pool *pool);
void sek_map_set(sek_map *map, const char *key, const char *val);
const char *sek_map_get(const sek_map *map, const char *key);

/* ---- string list --------------------------------------------------- */

typedef struct {
  sek_pool *pool;
  char **items;
  size_t len;
  size_t cap;
} sek_list;

sek_list *sek_list_new(sek_pool *pool);
void sek_list_add(sek_list *list, const char *text);

/* ---- json ---------------------------------------------------------- */

typedef enum {
  SEK_JSON_NULL = 0,
  SEK_JSON_BOOL,
  SEK_JSON_NUM,
  SEK_JSON_STR,
  SEK_JSON_ARR,
  SEK_JSON_OBJ
} sek_jsontype;

typedef struct sek_json sek_json;

struct sek_json {
  sek_jsontype type;
  int boolval;
  double numval;
  char *strval;
  sek_json **items; /* ARR */
  size_t itemlen;
  size_t itemcap;
  char **keys; /* OBJ, insertion ordered */
  sek_json **vals;
  size_t maplen;
  size_t mapcap;
};

/* Parse JSON text. Returns NULL when the text is not JSON - which is a
 * different answer from a parsed literal `null`, and fetchjson needs the
 * difference: only the first means the store could not answer. */
sek_json *sek_json_parse(sek_pool *pool, const char *text);

sek_json *sek_json_null(sek_pool *pool);
sek_json *sek_json_bool(sek_pool *pool, int val);
sek_json *sek_json_num(sek_pool *pool, double val);
sek_json *sek_json_str(sek_pool *pool, const char *val);
sek_json *sek_json_arr(sek_pool *pool);
sek_json *sek_json_obj(sek_pool *pool);
void sek_json_push(sek_pool *pool, sek_json *arr, sek_json *val);
void sek_json_set(sek_pool *pool, sek_json *obj, const char *key, sek_json *val);

/* Walk nested objects, stopping at the first missing step. NULL-terminated
 * key list: sek_json_dig(body, "auth", "client_token", NULL). */
sek_json *sek_json_dig(sek_json *val, ...);

/* Typed reads. Each answers NULL/0 for the wrong type, so a `__type` that
 * is not a string, or a vault list that is not an array, is not mistaken
 * for one. */
const char *sek_json_asstr(const sek_json *val);
const sek_json *sek_json_asarr(const sek_json *val);
const sek_json *sek_json_asobj(const sek_json *val);

/* Printable text, or NULL. A JSON null yields NULL, so a null field is a
 * miss rather than the string "null". */
const char *sek_json_text(sek_pool *pool, const sek_json *val);

char *sek_json_stringify(sek_pool *pool, const sek_json *val);
char *sek_json_quote(sek_pool *pool, const char *text);

/* A JSON number as every port prints it: 1 rather than 1.0. */
char *sek_numstr(sek_pool *pool, double val);

/* ---- names --------------------------------------------------------- */

/* Is this a well-formed secret name? NULL, empty and anything outside
 * `[a-z0-9_]` per dot-separated segment answer false. Never fails. */
int sek_validname(const char *name);

/* The name, or `sekreto: invalid name: <name>`. Every entry point checks
 * its name here. A NULL name renders as the empty string. */
sek_err sek_checkname(sek_pool *pool, const char *name);

sek_err sek_envkey(sek_pool *pool, const char *name, const char *prefix, char **out);

typedef struct {
  char *path;
  char *field;
} sek_vaultref;

sek_err sek_vaultref_of(sek_pool *pool, const char *name, sek_vaultref *out);
sek_err sek_flatname(sek_pool *pool, const char *name, const char *sep, char **out);
sek_err sek_awsparam(sek_pool *pool, const char *name, const char *prefix, char **out);

/* Parse `.env` text. Never fails: a NULL input is an empty map. */
sek_map *sek_parsedotenv(sek_pool *pool, const char *text);

/* Replace every value of four characters or more with `[redacted]`,
 * longest first. A NULL text answers "". */
char *sek_redact(sek_pool *pool, const char *text, const sek_list *values);

/* ---- provider ------------------------------------------------------ */

typedef struct sek_provider sek_provider;

struct sek_provider {
  /* The value, or a miss (`*out = NULL`), or an error. */
  sek_err (*lookup)(sek_provider *self, const char *name, char **out);
  /* A short description, shown by sek_sources. Leads with the kind. */
  const char *(*describe)(sek_provider *self);
  void *data;
  sek_pool *pool;
};

/* The store name a provider answers to when nothing says otherwise:
 * describe() up to the first `:`. */
char *sek_storename(sek_pool *pool, sek_provider *provider);

/* A provider with its two function pointers and its private data filled
 * in. Every kind uses it, built in or plugin, shipped or a consumer's
 * own, so there is one shape and not two. */
sek_provider *sek_provider_new(sek_pool *pool,
                               sek_err (*lookup)(sek_provider *, const char *, char **),
                               const char *(*describe)(sek_provider *), void *data);

/* A spec string, copied into the pool: a spec is the caller's and may be
 * a stack value that is gone by the first lookup, while the provider
 * built from it lives as long as the pool. */
const char *sek_own(sek_pool *pool, const char *text);

/* ---- provider specs ------------------------------------------------ */

/* Logging in to a vault instead of being handed a token. */
typedef struct {
  const char *method;
  const char *mount;
  const char *role;
  const char *jwt;
  const char *jwtfile;
  const char *roleid;
  const char *secretid;
} sek_authspec;

/* The declarative form of a provider, as used in config and in the shared
 * spec. `kind` picks the provider; everything else is that kind's own.
 * Every string field defaults to NULL, which means the same as empty
 * everywhere in this library: "not configured". */
typedef struct {
  const char *kind;
  const char *name;
  const char *prefix;
  const char *file;
  sek_map *values;
  const char *dir;
  const char *addr;
  const char *token;
  const char *mount;
  int kv; /* 0 means unset, so the default of 2 still applies. */
  int haskv;
  const char *vaultnamespace;
  sek_authspec *auth;
  const char *command;
  const char *profile;
  const char *backend;
  const char *reason;
  const char *namespace_;
  const char *home;
  const char *region;
  const char *keyid;
  const char *secret;
  const char *session;
  const char *project;
  const char *vault;
  const char *tenant;
  const char *clientid;
  const char *clientsecret;
  const char *loginaddr;
  const char *imdsaddr;
  const char *metadataaddr;
  const char *apiversion;
  const char *config;
  const char *environment;
  const char *path;

  /* A provider already built, joining the chain as it is - `kind` unset.
   * This is how a custom provider that is not a plugin gets in. Never
   * serialized into an instance's options: a live provider is not data. */
  sek_provider *provider;
} sek_spec;

/* A spec with every field at its default. */
sek_spec sek_spec_new(const char *kind);

/* Printed without its credentials: the obvious debug print of a chain
 * that will not build would otherwise put the Vault token, the AWS secret
 * key and the Azure client secret wherever it was printed. */
char *sek_spec_show(sek_pool *pool, const sek_spec *spec);
char *sek_authspec_show(sek_pool *pool, const sek_authspec *auth);

/* ---- provider kinds, as voxgig/plugin definitions ------------------ */

/* The export key a provider definition publishes its provider under.
 * sek_new reads `<ref>/provider` back off the host. */
#define SEK_PROVIDER_EXPORT "provider"

/* The voxgig/plugin error code a sekreto refusal travels under.
 *
 * plugin wraps an error raised in `define` as `plugin_define_failed` and
 * keeps one that already carries a code. A provider that refuses its own
 * configuration - `kv: 3`, a missing project - refuses with a message the
 * shared spec pins byte for byte, so it must come back out of the host
 * exactly as it went in. sek_providerplugin puts this code on; sek_new
 * takes it off. Nowhere else catches or rewraps. */
#define SEK_ERROR_CODE "sekreto_error"

/* How a kind builds its provider from a spec. The pool is the one the
 * Sekreto is being built with, and the provider must outlive the call. */
typedef sek_err (*sek_makefn)(sek_pool *pool, const sek_spec *spec, sek_provider **out);

/* A provider kind, as a voxgig/plugin definition.
 *
 * `def` IS FIRST AND MUST STAY FIRST. plugin's Definition is data with
 * function pointers in it and carries no context, so the one shared
 * `define` finds its kind's `make` by asking the host's catalog for the
 * definition it registered and casting that back to this struct. A
 * Definition that is not the first member of one of these is not a
 * provider plugin, and sek_new says so rather than dereferencing it. */
typedef struct {
  Definition def;
  sek_makefn make;
} sek_providerkind;

/* A provider kind, in one call. `slot` is the caller's storage - a file
 * scope static in each of the shipped plugins - and the answer is the
 * definition to hand to sek_options.plugins:
 *
 *     static sek_providerkind KIND;
 *
 *     Definition *sek_plugin_mystore(void) {
 *       return sek_providerplugin(&KIND, "mystore", mystore_make);
 *     }
 *
 * Nothing runs at activate: a provider opens nothing until its first
 * lookup, so there is nothing to capture. A provider that does hold a
 * resource acquires it there and lets the instance scope unwind it. */
Definition *sek_providerplugin(sek_providerkind *slot, const char *kind, sek_makefn make);

/* The four built-in kinds, as definitions, in the order sek_new puts them
 * in a catalog. Answers the count. */
size_t sek_builtins(Definition ***out);

/* Every kind this library ships, built in or as a plugin, so that an
 * unknown kind can be told from a plugin that was not passed in. Both are
 * NULL-terminated. */
extern const char *const SEK_BUILTIN_KINDS[];
extern const char *const SEK_PLUGIN_KINDS[];

/* ---- addresses ----------------------------------------------------- */

/* An address with any userinfo replaced by `[redacted]`, for messages. */
char *sek_safeaddr(sek_pool *pool, const char *addr);

/* Refuse to send a secret-bearing credential in the clear. Hand-parsed,
 * never with a platform URL type: twelve parsers disagree about malformed
 * input, and a check that answers differently per port is not a check. */
sek_err sek_checkaddr(sek_pool *pool, const char *addr);

/* ---- sekreto ------------------------------------------------------- */

typedef struct sek_sekreto sek_sekreto;

/* What a Sekreto is built from. Zeroed means: an empty chain, the four
 * built-in kinds, and caching on. */
typedef struct {
  /* The chain, in resolution order. Each entry names a kind to build - a
   * built-in, or a plugin passed below - or carries a provider already
   * built. */
  const sek_spec *providers;
  size_t count;

  /* The provider kinds beyond the built-ins that `providers` may name.
   *
   * STATIC AND EXPLICIT. The calling project names the plugin objects it
   * links and passes their definitions here; a kind it did not pass is
   * unknown to this Sekreto. There is no registry and nothing is
   * discovered: a list handed to a constructor cannot be erased by a
   * compiler, and a linker cannot drop what a translation unit names. */
  Definition **plugins;
  size_t plugincount;

  /* Nonzero disables the resolved-value cache. Spelled as the negative so
   * that a zeroed sek_options is a Sekreto that caches, which is the
   * documented default. */
  int nocache;
} sek_options;

/* A chain from its options - the same declarative shape the shared spec
 * and an app's config file use.
 *
 * Construction contacts nothing: `load` runs each kind's `define`, which
 * builds the provider, and `activate` takes the instance live. It may
 * still fail - a kind the catalog does not hold, a store name that is not
 * a valid plugin tag, or a provider refusing its own configuration.
 *
 * NOT REENTRANT. The pool a `define` allocates from reaches it through a
 * file-scope slot held for the duration of this call, because plugin's
 * Definition carries no context; a second construction from another
 * thread while this one is running is undefined. voxgig/plugin's own C
 * port claims no thread safety either, for the same kind of reason. */
sek_err sek_new(sek_pool *pool, const sek_options *options, sek_sekreto **out);

/* The voxgig/plugin host every spec'd provider is an instance of. Read it
 * for introspection - host_list names each store's ref and status - and
 * nothing on it advances the chain. */
Host *sek_host(sek_sekreto *sek);

/* The definitions this Sekreto can build: the built-ins, then whatever
 * sek_options.plugins handed in. A plugin naming a built-in kind replaces
 * it. */
Catalog *sek_catalog(sek_sekreto *sek);

/* The secret, or `sekreto: unknown secret: <name>`. */
sek_err sek_get(sek_sekreto *sek, const char *name, char **out);

/* The secret, or a miss (`*out = NULL`). Named `sek_try` after canonical's
 * `try`, which is a keyword in several of the ports. */
sek_err sek_try(sek_sekreto *sek, const char *name, char **out);

/* The secret from one named store. Naming a store that is not in the
 * chain is an error, not a miss - and it is raised before the name is
 * validated. */
sek_err sek_getfrom(sek_sekreto *sek, const char *store, const char *name, char **out);
sek_err sek_tryfrom(sek_sekreto *sek, const char *store, const char *name, char **out);

sek_err sek_has(sek_sekreto *sek, const char *name, int *out);
sek_err sek_hasin(sek_sekreto *sek, const char *store, const char *name, int *out);

/* Every named secret at once. Missing ones are an error. */
sek_err sek_all(sek_sekreto *sek, const char **names, size_t count, sek_map **out);

/* A description of each provider, in resolution order, repeats kept. */
sek_list *sek_sources(sek_sekreto *sek);

/* The name of each store `sek_getfrom` can address, in resolution order
 * and without repeats. */
sek_list *sek_stores(sek_sekreto *sek);

/* Replace every value this Sekreto has resolved with `[redacted]`. Works
 * whether or not caching is on, and keeps working after sek_close. */
char *sek_redact_text(sek_sekreto *sek, const char *text);

/* Drop cached values, so the next read asks the providers again. The
 * redaction history is not a cache and survives this. */
void sek_refresh(sek_sekreto *sek);

/* Tear the chain down: every plugin instance is deactivated and unloaded,
 * in reverse, releasing whatever a provider acquired at activation.
 * Afterwards the chain is empty, reads miss, and redaction still knows
 * every value ever resolved.
 *
 * Answers an error because a hand-written definition may refuse to close;
 * none of the kinds this library ships does. */
sek_err sek_close(sek_sekreto *sek);

/* The print hook. `cache` and `seen` are ordinary fields, so a debug
 * print of a Sekreto would otherwise emit every resolved secret; this one
 * cannot reach a value. */
char *sek_show(sek_sekreto *sek);

#endif /* VOXGIG_SEKRETO_H */
