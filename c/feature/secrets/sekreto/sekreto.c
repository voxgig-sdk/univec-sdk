// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/src/sekreto.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* sekreto: one interface for secrets, wherever they live.
 *
 * A Sekreto is an ordered chain of providers. `get` asks each in turn and
 * returns the first hit, so an app can be configured from environment
 * variables in development and a vault in production without changing a
 * line of its own code.
 *
 * This file holds the facade and every pure name function, and it builds
 * the chain on a voxgig/plugin host: each spec'd provider is an instance
 * addressed by name+tag, `load` runs the kind's `define` and `activate`
 * takes it live. Nothing here opens a socket, runs a child or touches a
 * certificate - and neither does anything else under `src/`. The kinds
 * that do are plugins under `plugins/`, and only a link line that names
 * one carries them.
 *
 * A port of typescript/src/Sekreto.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <string.h>

#include "internal.h"

/* ---- names --------------------------------------------------------- */

/* Scanned character by character rather than matched against
 * `^[a-z0-9_]+$`, and that is deliberate. In Python, PCRE, Perl and .NET
 * `$` also matches before a final newline, so four ports accepted
 * `api.token\n` as a valid name; the spec pins it, `api\n.token` and
 * `api.token\r` as invalid. A scan cannot have that bug. */
int sek_validname(const char *name) {
  size_t index;
  size_t seglen = 0;

  if (NULL == name || '\0' == name[0]) {
    return 0;
  }

  for (index = 0; '\0' != name[index]; index++) {
    char ch = name[index];

    if ('.' == ch) {
      if (0 == seglen) {
        return 0;
      }
      seglen = 0;
      continue;
    }

    if (!(('a' <= ch && 'z' >= ch) || ('0' <= ch && '9' >= ch) || '_' == ch)) {
      return 0;
    }

    seglen++;
  }

  return 0 < seglen;
}

sek_err sek_checkname(sek_pool *pool, const char *name) {
  if (sek_validname(name)) {
    return NULL;
  }

  /* A NULL name renders as the empty string, so the message ends with a
   * trailing space - which the spec pins, byte for byte. */
  return sek_fmt(pool, "sekreto: invalid name: %s", sek_orempty(name));
}

/* The segments of a name, which every function below wants. */
static sek_list *segments(sek_pool *pool, const char *name) {
  sek_list *out = sek_list_new(pool);
  const char *at = name;

  for (;;) {
    const char *dot = strchr(at, '.');
    if (NULL == dot) {
      sek_list_add(out, at);
      return out;
    }
    sek_list_add(out, sek_strndup(pool, at, (size_t)(dot - at)));
    at = dot + 1;
  }
}

/* The environment-variable key for a name: `api.token` -> `API_TOKEN`.
 * The prefix is NOT uppercased - it arrives as configured. */
sek_err sek_envkey(sek_pool *pool, const char *name, const char *prefix, char **out) {
  sek_err err = sek_checkname(pool, name);
  sek_buf buf;
  size_t index;

  if (NULL != err) {
    return err;
  }

  sek_buf_init(&buf, pool);
  sek_buf_add(&buf, sek_orempty(prefix));

  for (index = 0; '\0' != name[index]; index++) {
    sek_buf_addch(&buf, '.' == name[index] ? '_' : sek_upper(name[index]));
  }

  *out = buf.data;

  return NULL;
}

/* Where a name lives in a KV vault: `api.token` -> `api` / `token`. A
 * single-segment name has no path of its own, so it becomes a secret of
 * that name with the conventional field `value`. */
sek_err sek_vaultref_of(sek_pool *pool, const char *name, sek_vaultref *out) {
  sek_err err = sek_checkname(pool, name);
  sek_list *parts;
  sek_buf path;
  size_t index;

  if (NULL != err) {
    return err;
  }

  parts = segments(pool, name);

  if (1 == parts->len) {
    out->path = parts->items[0];
    out->field = sek_strdup(pool, "value");
    return NULL;
  }

  sek_buf_init(&path, pool);
  for (index = 0; index + 1 < parts->len; index++) {
    if (0 < index) {
      sek_buf_addch(&path, '/');
    }
    sek_buf_add(&path, parts->items[index]);
  }

  out->path = path.data;
  out->field = parts->items[parts->len - 1];

  return NULL;
}

/* A name flattened to one segment: `api.token` -> `api_token` (GCP Secret
 * Manager) or `api-token` (Azure Key Vault). With `-` as the separator
 * underscores flatten too, because Key Vault's alphabet is letters,
 * digits and hyphens only and `with_underscore` must still be
 * representable there. */
sek_err sek_flatname(sek_pool *pool, const char *name, const char *sep, char **out) {
  sek_err err = sek_checkname(pool, name);
  sek_buf buf;
  size_t index;
  int hyphen;

  if (NULL != err) {
    return err;
  }

  hyphen = NULL != sep && 0 == strcmp(sep, "-");

  sek_buf_init(&buf, pool);

  for (index = 0; '\0' != name[index]; index++) {
    char ch = name[index];
    if ('.' == ch) {
      sek_buf_add(&buf, sek_orempty(sep));
    } else if (hyphen && '_' == ch) {
      sek_buf_addch(&buf, '-');
    } else {
      sek_buf_addch(&buf, ch);
    }
  }

  *out = buf.data;

  return NULL;
}

/* The AWS SSM Parameter Store name: dots become the path hierarchy,
 * rooted at `/` or at a prefix. `db.pass.main` -> `/db/pass/main`. */
sek_err sek_awsparam(sek_pool *pool, const char *name, const char *prefix, char **out) {
  sek_err err = sek_checkname(pool, name);
  sek_buf buf;
  const char *base = sek_orempty(prefix);
  size_t index;

  if (NULL != err) {
    return err;
  }

  sek_buf_init(&buf, pool);

  if ('\0' != base[0]) {
    size_t len = strlen(base);
    if ('/' != base[0]) {
      sek_buf_addch(&buf, '/');
    }
    if (0 < len && '/' == base[len - 1]) {
      sek_buf_addn(&buf, base, len - 1);
    } else {
      sek_buf_add(&buf, base);
    }
  }

  sek_buf_addch(&buf, '/');

  for (index = 0; '\0' != name[index]; index++) {
    sek_buf_addch(&buf, '.' == name[index] ? '/' : name[index]);
  }

  *out = buf.data;

  return NULL;
}

/* ---- .env ---------------------------------------------------------- */

/* `\n \r \t \\ \"` become their characters; ANY OTHER escape is preserved
 * as backslash plus character, and a trailing backslash is literal. A
 * scan, not a chain of replacements - a chain would rewrite the output of
 * the step before it. */
static char *unescape(sek_pool *pool, const char *text, size_t len) {
  sek_buf out;
  size_t index = 0;

  sek_buf_init(&out, pool);

  while (index < len) {
    if ('\\' == text[index] && index + 1 < len) {
      char next = text[index + 1];
      index += 2;

      switch (next) {
      case 'n':
        sek_buf_addch(&out, '\n');
        break;
      case 'r':
        sek_buf_addch(&out, '\r');
        break;
      case 't':
        sek_buf_addch(&out, '\t');
        break;
      case '\\':
        sek_buf_addch(&out, '\\');
        break;
      case '"':
        sek_buf_addch(&out, '"');
        break;
      default:
        sek_buf_addch(&out, '\\');
        sek_buf_addch(&out, next);
        break;
      }

      continue;
    }

    sek_buf_addch(&out, text[index]);
    index++;
  }

  return out.data;
}

static char *trim(sek_pool *pool, const char *text, size_t len) {
  size_t start = 0;
  size_t end = len;

  while (start < end && (' ' == text[start] || '\t' == text[start] || '\r' == text[start] ||
                         '\n' == text[start] || '\v' == text[start] || '\f' == text[start])) {
    start++;
  }
  while (end > start && (' ' == text[end - 1] || '\t' == text[end - 1] || '\r' == text[end - 1] ||
                         '\n' == text[end - 1] || '\v' == text[end - 1] || '\f' == text[end - 1])) {
    end--;
  }

  return sek_strndup(pool, text + start, end - start);
}

/* Deliberately small: `KEY=value`, optional `export`, `#` comments on
 * their own line, and single- or double-quoted values. There is no `.env`
 * standard, so this function IS the specification, and every clause of it
 * is pinned by the corpus. */
sek_map *sek_parsedotenv(sek_pool *pool, const char *text) {
  sek_map *out = sek_map_new(pool);
  const char *at;

  if (NULL == text) {
    return out;
  }

  at = text;

  for (;;) {
    const char *nl = strchr(at, '\n');
    size_t rawlen = NULL == nl ? strlen(at) : (size_t)(nl - at);
    char *line;
    const char *body;
    const char *eq;
    char *key;
    char *value;
    size_t vlen;

    /* One trailing `\r`, then the whole line trimmed. */
    if (0 < rawlen && '\r' == at[rawlen - 1]) {
      rawlen--;
    }
    line = trim(pool, at, rawlen);

    if ('\0' == line[0] || '#' == line[0]) {
      goto next;
    }

    /* A literal leading `export `, then a re-trim. */
    body = sek_has_prefix(line, "export ") ? trim(pool, line + 7, strlen(line + 7)) : line;

    eq = strchr(body, '=');
    /* Both "no `=`" and "empty key" are skipped silently, without
     * abandoning the rest of the file. */
    if (NULL == eq || eq == body) {
      goto next;
    }

    key = trim(pool, body, (size_t)(eq - body));
    value = trim(pool, eq + 1, strlen(eq + 1));
    vlen = strlen(value);

    if (2 <= vlen && '"' == value[0] && '"' == value[vlen - 1]) {
      value = unescape(pool, value + 1, vlen - 2);
    } else if (2 <= vlen && '\'' == value[0] && '\'' == value[vlen - 1]) {
      value = sek_strndup(pool, value + 1, vlen - 2);
    }

    /* Keys verbatim, no case folding; a later duplicate overwrites. */
    sek_map_set(out, key, value);

  next:
    if (NULL == nl) {
      return out;
    }
    at = nl + 1;
  }
}

/* ---- redact -------------------------------------------------------- */

/* Only values of four characters or more are replaced: shorter ones are
 * too likely to appear in ordinary text, and redacting them would make
 * logs unreadable without making them safer.
 *
 * Longest first, always. The corpus pins both arrival orders of
 * ['abcd','abcd1234'] against `token=abcd1234`, so the case cannot pass
 * by luck - the short value would otherwise chew the long one in half.
 *
 * The sort is over a COPY: the caller's list is `seen` when this is
 * reached through sek_redact_text, and sorting in place would reorder the
 * live redaction history. */
char *sek_redact(sek_pool *pool, const char *text, const sek_list *values) {
  sek_list *usable = sek_list_new(pool);
  char *out = sek_strdup(pool, NULL == text ? "" : text);
  size_t index;

  if (NULL == values) {
    return out;
  }

  for (index = 0; index < values->len; index++) {
    if (NULL != values->items[index] && 4 <= strlen(values->items[index])) {
      sek_list_add(usable, values->items[index]);
    }
  }

  for (index = 1; index < usable->len; index++) {
    char *value = usable->items[index];
    size_t back = index;

    while (0 < back && strlen(usable->items[back - 1]) < strlen(value)) {
      usable->items[back] = usable->items[back - 1];
      back--;
    }

    usable->items[back] = value;
  }

  for (index = 0; index < usable->len; index++) {
    const char *value = usable->items[index];
    size_t vlen = strlen(value);
    sek_buf next;
    const char *rest = out;

    sek_buf_init(&next, pool);

    /* A literal substring replace-all, never a regex: a secret containing
     * metacharacters must not be interpreted as a pattern. */
    for (;;) {
      const char *found = strstr(rest, value);
      if (NULL == found) {
        sek_buf_add(&next, rest);
        break;
      }
      sek_buf_addn(&next, rest, (size_t)(found - rest));
      sek_buf_add(&next, "[redacted]");
      rest = found + vlen;
    }

    out = next.data;
  }

  return out;
}

/* ---- the chain ----------------------------------------------------- */

/* The store name a provider answers to when nothing says otherwise.
 * describe() opens with the provider's kind - `hashicorp:...`,
 * `dotenv:...`, plain `env` - so the kind is the natural default. */
char *sek_storename(sek_pool *pool, sek_provider *provider) {
  const char *text = provider->describe(provider);
  const char *colon = strchr(text, ':');

  return NULL == colon ? sek_strdup(pool, text) : sek_strndup(pool, text, (size_t)(colon - text));
}

typedef struct {
  char *store;
  /* The plugin instance that built this provider - "" for one handed in
   * already built, which no instance backs. */
  const char *ref;
  sek_provider *provider;
} entry;

typedef struct {
  char *store;
  char *name;
  char *value;
} cached;

struct sek_sekreto {
  sek_pool *pool;

  /* The voxgig/plugin host every spec'd provider is an instance of, and
   * the catalog of definitions it can build: the built-ins, then whatever
   * sek_options.plugins handed in. */
  Host *host;
  Catalog *catalog;

  entry *entries;
  size_t count;
  int docache;

  cached *cache;
  size_t cachelen;
  size_t cachecap;

  /* Every value ever resolved, for redaction. Kept independently of the
   * read cache, so `nocache` does not silently disable sek_redact_text
   * and leak secrets to logs, and append-only for the object's life: not
   * cleared by sek_refresh, not cleared by sek_close. */
  sek_list *seen;
};

Host *sek_host(sek_sekreto *sek) { return sek->host; }

Catalog *sek_catalog(sek_sekreto *sek) { return sek->catalog; }

/* The message for a kind the catalog does not hold.
 *
 * A kind sekreto has never heard of is a typo; a kind that exists as a
 * plugin but was not passed in is the split working as designed and
 * telling you what to pass. Collapsing the two was the first thing that
 * made the split confusing to use. */
static sek_err unknownkind(sek_pool *pool, const char *kind, Catalog *catalog) {
  Value *names = catalog_names(catalog);
  sek_buf out;
  size_t index;

  sek_buf_init(&out, pool);
  sek_buf_addfmt(&out, "sekreto: unknown provider kind: %s (available: ", kind);

  for (index = 0; index < vlen(names); index++) {
    if (0 < index) {
      sek_buf_add(&out, ", ");
    }
    sek_buf_add(&out, vasstr(vat(names, index)));
  }

  sek_buf_addch(&out, ')');

  for (index = 0; NULL != SEK_PLUGIN_KINDS[index]; index++) {
    if (0 == strcmp(SEK_PLUGIN_KINDS[index], kind)) {
      sek_buf_addfmt(&out,
                     " - %s is a sekreto plugin, not built in: pass it in the plugins option",
                     kind);
      break;
    }
  }

  return out.data;
}

/* A sekreto refusal that crossed the plugin boundary, back as itself,
 * byte for byte. Anything else is not sekreto's to rewrite and surfaces
 * as the host reports it, naming the instance and the cause. */
static sek_err unwrap(sek_pool *pool, PluginError *err) {
  if (NULL == err) {
    return sek_strdup(pool, "sekreto: the plugin host failed without saying why");
  }

  if (NULL != err->code && 0 == strcmp(SEK_ERROR_CODE, err->code)) {
    Value *cause = vget(err->details, "cause");
    if (visstr(cause)) {
      return sek_strdup(pool, vasstr(cause));
    }
  }

  return sek_strdup(pool, err->message);
}

/* One chain entry, as a plugin instance.
 *
 * The instance is `kind` for a store named after its kind and
 * `kind$store` otherwise - `hashicorp$prod` - so host_list reads like the
 * chain. A store name that is already taken gets a numbered tag from the
 * host instead, because two providers MAY share a store name (a directed
 * read walks both) and an instance ref may not.
 *
 * Raises through voxgig/plugin's `fail` for anything the host refuses;
 * sek_new is the frame that catches it. */
static sek_err declare(sek_sekreto *sek, const sek_spec *spec, entry *out) {
  const char *kind = sek_orempty(spec->kind);
  const char *store;
  const char *ref;
  DeclareSpec declared;
  Value *exported;
  sek_provider *provider;

  if (!catalog_has(sek->catalog, kind)) {
    return unknownkind(sek->pool, kind, sek->catalog);
  }

  store = sek_empty(spec->name) ? kind : spec->name;

  if (!checktag(vstr(store))) {
    return sek_fmt(sek->pool, "sekreto: invalid store name: %s", store);
  }

  ref = 0 == strcmp(store, kind) ? kind : formatref(vstr(kind), vstr(store));
  if (NULL != host_instance(sek->host, ref)) {
    ref = host_autotag(sek->host, kind);
  }

  memset(&declared, 0, sizeof(declared));
  declared.options = sek_optionsof(spec);

  /* `load` runs the definition's `define`, which builds the provider from
   * the spec; `activate` takes the instance live. Nothing is contacted by
   * either: a provider opens nothing until its first lookup. */
  host_load(sek->host, ref, &declared);
  host_activate(sek->host, ref);

  exported = host_exports(sek->host, sek_fmt(sek->pool, "%s/%s", ref, SEK_PROVIDER_EXPORT));
  provider = visnum(exported) ? sek_build_at(vasnum(exported)) : NULL;

  if (NULL == provider) {
    return sek_fmt(sek->pool, "sekreto: plugin %s exported no provider", kind);
  }

  out->store = sek_strdup(sek->pool, store);
  out->ref = sek_strdup(sek->pool, ref);
  out->provider = provider;

  return NULL;
}

/* The whole of construction, inside the caller's catch frame. */
static sek_err build(sek_sekreto *sek, const sek_options *options) {
  Definition **builtins;
  size_t count = sek_builtins(&builtins);
  size_t index;

  /* Built-ins first, then the plugins, into one catalog: a plugin that
   * names a built-in kind replaces it, which is how a host substitutes an
   * implementation and never an accident, because the four names are
   * documented. */
  for (index = 0; index < count; index++) {
    catalog_add(sek->catalog, builtins[index]);
  }
  for (index = 0; index < options->plugincount; index++) {
    catalog_add(sek->catalog, options->plugins[index]);
  }

  for (index = 0; index < options->count; index++) {
    const sek_spec *spec = &options->providers[index];
    sek_err err;

    /* A provider already built joins the chain as it is, under its own
     * store name, backed by no instance. */
    if (NULL != spec->provider) {
      sek->entries[sek->count].provider = spec->provider;
      sek->entries[sek->count].ref = "";
      sek->entries[sek->count].store = sek_empty(spec->name)
                                           ? sek_storename(sek->pool, spec->provider)
                                           : sek_strdup(sek->pool, spec->name);
      sek->count++;
      continue;
    }

    err = declare(sek, spec, &sek->entries[sek->count]);
    if (NULL != err) {
      return err;
    }
    sek->count++;
  }

  return NULL;
}

/* Construction, inside the one catch frame the whole of it runs under.
 *
 * Its own function so that nothing a `longjmp` comes back through is a
 * parameter this code then modifies: `options` and `sek` are read-only
 * here, and only `failure` straddles the frame. -Wclobbered is on, and it
 * is the warning that catches exactly this. */
static sek_err construct(sek_pool *pool, const sek_options *options, sek_sekreto *sek) {
  CatchFrame frame;
  /* volatile because it is written inside the frame and read after a
   * longjmp has come back through it. C guarantees nothing else about a
   * local a setjmp handler reads. */
  volatile sek_err failure = NULL;

  /* The pool reaches each kind's `define` through here, and the providers
   * come back the same way. Held for exactly this call. */
  sek_build_begin(pool);

  if (0 == PLUGIN_TRY(&frame)) {
    HostOptions hostopts;
    memset(&hostopts, 0, sizeof(hostopts));
    hostopts.catalog = sek->catalog;
    sek->host = makehost(&hostopts);

    failure = build(sek, options);
    PLUGIN_END(&frame);
  } else {
    failure = unwrap(pool, plugin_caught());
  }

  sek_build_end();

  return failure;
}

sek_err sek_new(sek_pool *pool, const sek_options *options, sek_sekreto **out) {
  sek_sekreto *sek = (sek_sekreto *)sek_alloc(pool, sizeof(sek_sekreto));
  sek_options empty;
  sek_err failure;

  memset(&empty, 0, sizeof(empty));

  sek->pool = pool;
  sek->catalog = makecatalog();
  sek->host = NULL;
  sek->count = 0;
  sek->docache = NULL == options || 0 == options->nocache;
  sek->entries = (entry *)sek_alloc(
      pool, (NULL == options || 0 == options->count ? 1 : options->count) * sizeof(entry));
  sek->cachecap = 8;
  sek->cache = (cached *)sek_alloc(pool, sek->cachecap * sizeof(cached));
  sek->cachelen = 0;
  sek->seen = sek_list_new(pool);

  failure = construct(pool, NULL == options ? &empty : options, sek);
  if (NULL != failure) {
    return failure;
  }

  *out = sek;

  return NULL;
}

static void remember(sek_sekreto *sek, const char *store, const char *name, const char *value) {
  if (sek->cachelen == sek->cachecap) {
    size_t cap = sek->cachecap * 2;
    cached *bigger = (cached *)sek_alloc(sek->pool, cap * sizeof(cached));
    memcpy(bigger, sek->cache, sek->cachelen * sizeof(cached));
    sek->cache = bigger;
    sek->cachecap = cap;
  }

  sek->cache[sek->cachelen].store = sek_strdup(sek->pool, store);
  sek->cache[sek->cachelen].name = sek_strdup(sek->pool, name);
  sek->cache[sek->cachelen].value = sek_strdup(sek->pool, value);
  sek->cachelen++;
}

/* The one path both readers share. `store` is "" for a transparent read,
 * so a directed read and a transparent one never alias in the cache.
 *
 * `only` is NULL for a transparent read and the store name for a directed
 * one, rather than a pre-filtered array of entries: filtering inline
 * keeps the walk allocation-free, and in an arena a per-call allocation
 * is never handed back. */
static sek_err resolve(sek_sekreto *sek, const char *store, const char *only, const char *name,
                       char **out) {
  size_t index;
  sek_err err;

  *out = NULL;

  /* The name is validated FIRST: before the cache, and before the first
   * provider is asked. */
  err = sek_checkname(sek->pool, name);
  if (NULL != err) {
    return err;
  }

  if (sek->docache) {
    for (index = 0; index < sek->cachelen; index++) {
      if (0 == strcmp(sek->cache[index].store, store) &&
          0 == strcmp(sek->cache[index].name, name)) {
        /* A cache hit does not push to `seen`: it is already there. */
        *out = sek->cache[index].value;
        return NULL;
      }
    }
  }

  for (index = 0; index < sek->count; index++) {
    char *found = NULL;

    if (NULL != only && 0 != strcmp(sek->entries[index].store, only)) {
      continue;
    }

    /* A provider that raises is not caught: the error propagates out of
     * get/try/getfrom/tryfrom, because a store that could not answer must
     * not be mistaken for one that answered "no". */
    err = sek->entries[index].provider->lookup(sek->entries[index].provider, name, &found);
    if (NULL != err) {
      return err;
    }

    /* THE EMPTY STRING IS A HIT. Only NULL means "ask the next one". */
    if (NULL != found) {
      if (sek->docache) {
        remember(sek, store, name, found);
      }
      sek_list_add(sek->seen, found);
      *out = found;
      return NULL;
    }
  }

  /* Misses are never cached. */
  return NULL;
}

sek_err sek_try(sek_sekreto *sek, const char *name, char **out) {
  return resolve(sek, "", NULL, name, out);
}

sek_err sek_get(sek_sekreto *sek, const char *name, char **out) {
  sek_err err = sek_try(sek, name, out);

  if (NULL != err) {
    return err;
  }

  if (NULL == *out) {
    return sek_fmt(sek->pool, "sekreto: unknown secret: %s", name);
  }

  return NULL;
}

/* Naming a store that is not in the chain is an error, not a miss:
 * `try` already means "this store may not have it", so it cannot also
 * mean "this store may not exist" without hiding a typo. Raised BEFORE
 * the name is validated. */
sek_err sek_tryfrom(sek_sekreto *sek, const char *store, const char *name, char **out) {
  size_t index;
  int found = 0;

  *out = NULL;

  /* Store names may repeat, and a directed read walks every entry that
   * answers to the name, in chain order. */
  for (index = 0; index < sek->count; index++) {
    if (0 == strcmp(sek->entries[index].store, store)) {
      found = 1;
      break;
    }
  }

  if (!found) {
    return sek_fmt(sek->pool, "sekreto: unknown store: %s", store);
  }

  return resolve(sek, store, store, name, out);
}

sek_err sek_getfrom(sek_sekreto *sek, const char *store, const char *name, char **out) {
  sek_err err = sek_tryfrom(sek, store, name, out);

  if (NULL != err) {
    return err;
  }

  if (NULL == *out) {
    return sek_fmt(sek->pool, "sekreto: unknown secret: %s:%s", store, name);
  }

  return NULL;
}

sek_err sek_has(sek_sekreto *sek, const char *name, int *out) {
  char *value = NULL;
  sek_err err = sek_try(sek, name, &value);

  *out = NULL != value;

  return err;
}

sek_err sek_hasin(sek_sekreto *sek, const char *store, const char *name, int *out) {
  char *value = NULL;
  sek_err err = sek_tryfrom(sek, store, name, &value);

  *out = NULL != value;

  return err;
}

sek_err sek_all(sek_sekreto *sek, const char **names, size_t count, sek_map **out) {
  sek_map *found = sek_map_new(sek->pool);
  size_t index;

  for (index = 0; index < count; index++) {
    char *value = NULL;
    sek_err err = sek_get(sek, names[index], &value);
    if (NULL != err) {
      return err;
    }
    sek_map_set(found, names[index], value);
  }

  *out = found;

  return NULL;
}

sek_list *sek_sources(sek_sekreto *sek) {
  sek_list *out = sek_list_new(sek->pool);
  size_t index;

  for (index = 0; index < sek->count; index++) {
    sek_provider *provider = sek->entries[index].provider;
    sek_list_add(out, provider->describe(provider));
  }

  return out;
}

sek_list *sek_stores(sek_sekreto *sek) {
  sek_list *out = sek_list_new(sek->pool);
  size_t index;

  for (index = 0; index < sek->count; index++) {
    size_t seen;
    int already = 0;

    for (seen = 0; seen < out->len; seen++) {
      if (0 == strcmp(out->items[seen], sek->entries[index].store)) {
        already = 1;
        break;
      }
    }

    if (!already) {
      sek_list_add(out, sek->entries[index].store);
    }
  }

  return out;
}

char *sek_redact_text(sek_sekreto *sek, const char *text) {
  return sek_redact(sek->pool, text, sek->seen);
}

void sek_refresh(sek_sekreto *sek) { sek->cachelen = 0; }

/* Every plugin instance is deactivated and unloaded, in reverse, which is
 * voxgig/plugin's teardown and not sekreto's: a provider that acquired a
 * resource at activation has it released here, by the instance scope.
 *
 * The chain and the cache go with them; `seen` stays, so redaction still
 * knows every value this Sekreto ever resolved. */
sek_err sek_close(sek_sekreto *sek) {
  CatchFrame frame;
  volatile sek_err failure = NULL;

  if (0 == PLUGIN_TRY(&frame)) {
    host_close(sek->host);
    PLUGIN_END(&frame);
  } else {
    failure = unwrap(sek->pool, plugin_caught());
  }

  sek->count = 0;
  sek->cachelen = 0;

  return failure;
}

/* `cache` and `seen` are ordinary fields, so the obvious debug print of a
 * Sekreto would emit every resolved secret. This one cannot reach a
 * value. The spacing is literal: an empty chain yields
 * `Sekreto { stores: [  ] }`. */
char *sek_show(sek_sekreto *sek) {
  sek_list *stores = sek_stores(sek);
  sek_buf out;
  size_t index;

  sek_buf_init(&out, sek->pool);
  sek_buf_add(&out, "Sekreto { stores: [ ");

  for (index = 0; index < stores->len; index++) {
    if (0 < index) {
      sek_buf_add(&out, ", ");
    }
    sek_buf_add(&out, stores->items[index]);
  }

  sek_buf_add(&out, " ] }");

  return out.data;
}
