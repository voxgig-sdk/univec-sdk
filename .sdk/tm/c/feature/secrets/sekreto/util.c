// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/src/util.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The arena, the buffer, and the two ordered containers everything else
 * is built from.
 *
 * C has no garbage collector and this library hands strings back at every
 * turn - a secret, a describe(), an error message - so ownership is the
 * first thing to settle. It is settled by not having any: every
 * allocation comes from one arena, and the arena is freed in one call.
 * There is no free() anywhere else in this port, which means there is no
 * double free, no use-after-free and no leak on an error path - the arm
 * every C library gets wrong.
 *
 * The cost is that a long-lived Sekreto accumulates. That is the right
 * trade for a library read on an application's startup path and for a CLI
 * that exits: the alternative is refcounting every string that crosses
 * the provider boundary, which is where the bugs live.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

/* One arena block. Blocks are chained, never moved: a pointer handed out
 * stays valid for the life of the pool however much is allocated after
 * it. */
typedef struct sek_block {
  struct sek_block *next;
  size_t used;
  size_t size;
  char *data;
} sek_block;

struct sek_pool {
  sek_block *head;
};

#define BLOCKSIZE (64 * 1024)

/* An allocation failure in a secrets library is not something to paper
 * over: continuing with a half-filled buffer could put the wrong bytes in
 * an Authorization header. */
static void nomemory(void) {
  fputs("sekreto: out of memory\n", stderr);
  abort();
}

sek_pool *sek_pool_new(void) {
  sek_pool *pool = (sek_pool *)calloc(1, sizeof(sek_pool));
  if (NULL == pool) {
    nomemory();
  }
  return pool;
}

void sek_pool_free(sek_pool *pool) {
  sek_block *block;

  if (NULL == pool) {
    return;
  }

  block = pool->head;
  while (NULL != block) {
    sek_block *next = block->next;
    free(block->data);
    free(block);
    block = next;
  }

  free(pool);
}

void *sek_alloc(sek_pool *pool, size_t size) {
  sek_block *block;
  void *out;

  /* Every allocation is pointer-aligned, so a struct may be carved out of
   * the arena as safely as a string. */
  size = (size + 15u) & ~(size_t)15u;
  if (0 == size) {
    size = 16;
  }

  block = pool->head;
  if (NULL == block || block->size - block->used < size) {
    size_t want = size > BLOCKSIZE ? size : BLOCKSIZE;

    block = (sek_block *)calloc(1, sizeof(sek_block));
    if (NULL == block) {
      nomemory();
    }

    block->data = (char *)calloc(1, want);
    if (NULL == block->data) {
      nomemory();
    }

    block->size = want;
    block->used = 0;
    block->next = pool->head;
    pool->head = block;
  }

  out = block->data + block->used;
  block->used += size;

  return out;
}

char *sek_strndup(sek_pool *pool, const char *text, size_t len) {
  char *out;

  if (NULL == text) {
    return NULL;
  }

  out = (char *)sek_alloc(pool, len + 1);
  memcpy(out, text, len);
  out[len] = '\0';

  return out;
}

char *sek_strdup(sek_pool *pool, const char *text) {
  if (NULL == text) {
    return NULL;
  }
  return sek_strndup(pool, text, strlen(text));
}

char *sek_fmt(sek_pool *pool, const char *fmt, ...) {
  va_list args;
  va_list again;
  int want;
  char *out;

  va_start(args, fmt);
  va_copy(again, args);
  want = vsnprintf(NULL, 0, fmt, args);
  va_end(args);

  if (0 > want) {
    va_end(again);
    return sek_strdup(pool, "");
  }

  out = (char *)sek_alloc(pool, (size_t)want + 1);
  vsnprintf(out, (size_t)want + 1, fmt, again);
  va_end(again);

  return out;
}

/* ---- buffer -------------------------------------------------------- */

void sek_buf_init(sek_buf *buf, sek_pool *pool) {
  buf->pool = pool;
  buf->cap = 64;
  buf->data = (char *)sek_alloc(pool, buf->cap);
  buf->data[0] = '\0';
  buf->len = 0;
}

/* Grown by copying into a fresh arena slice: the old one is simply left
 * behind, which is the arena's whole bargain. Doubling keeps the total
 * abandoned below the live size. */
static void grow(sek_buf *buf, size_t want) {
  size_t cap = buf->cap;
  char *data;

  if (want <= cap) {
    return;
  }

  while (cap < want) {
    cap *= 2;
  }

  data = (char *)sek_alloc(buf->pool, cap);
  memcpy(data, buf->data, buf->len);
  data[buf->len] = '\0';

  buf->data = data;
  buf->cap = cap;
}

void sek_buf_addn(sek_buf *buf, const char *text, size_t len) {
  if (NULL == text || 0 == len) {
    return;
  }

  grow(buf, buf->len + len + 1);
  memcpy(buf->data + buf->len, text, len);
  buf->len += len;
  buf->data[buf->len] = '\0';
}

void sek_buf_add(sek_buf *buf, const char *text) {
  if (NULL == text) {
    return;
  }
  sek_buf_addn(buf, text, strlen(text));
}

void sek_buf_addch(sek_buf *buf, char ch) { sek_buf_addn(buf, &ch, 1); }

void sek_buf_addfmt(sek_buf *buf, const char *fmt, ...) {
  va_list args;
  va_list again;
  int want;

  va_start(args, fmt);
  va_copy(again, args);
  want = vsnprintf(NULL, 0, fmt, args);
  va_end(args);

  if (0 > want) {
    va_end(again);
    return;
  }

  grow(buf, buf->len + (size_t)want + 1);
  vsnprintf(buf->data + buf->len, (size_t)want + 1, fmt, again);
  va_end(again);
  buf->len += (size_t)want;
}

/* ---- ordered string map -------------------------------------------- */

sek_map *sek_map_new(sek_pool *pool) {
  sek_map *map = (sek_map *)sek_alloc(pool, sizeof(sek_map));
  map->pool = pool;
  map->cap = 8;
  map->keys = (char **)sek_alloc(pool, map->cap * sizeof(char *));
  map->vals = (char **)sek_alloc(pool, map->cap * sizeof(char *));
  map->len = 0;
  return map;
}

void sek_map_set(sek_map *map, const char *key, const char *val) {
  size_t index;

  for (index = 0; index < map->len; index++) {
    if (0 == strcmp(map->keys[index], key)) {
      /* A later duplicate overwrites, keeping the original position: a
       * .env file that sets a key twice means the last value, and the
       * spec compares whole maps, so the order must not shuffle. */
      map->vals[index] = sek_strdup(map->pool, val);
      return;
    }
  }

  if (map->len == map->cap) {
    size_t cap = map->cap * 2;
    char **keys = (char **)sek_alloc(map->pool, cap * sizeof(char *));
    char **vals = (char **)sek_alloc(map->pool, cap * sizeof(char *));
    memcpy(keys, map->keys, map->len * sizeof(char *));
    memcpy(vals, map->vals, map->len * sizeof(char *));
    map->keys = keys;
    map->vals = vals;
    map->cap = cap;
  }

  map->keys[map->len] = sek_strdup(map->pool, key);
  map->vals[map->len] = sek_strdup(map->pool, val);
  map->len++;
}

const char *sek_map_get(const sek_map *map, const char *key) {
  size_t index;

  if (NULL == map || NULL == key) {
    return NULL;
  }

  for (index = 0; index < map->len; index++) {
    if (0 == strcmp(map->keys[index], key)) {
      return map->vals[index];
    }
  }

  return NULL;
}

/* ---- string list --------------------------------------------------- */

sek_list *sek_list_new(sek_pool *pool) {
  sek_list *list = (sek_list *)sek_alloc(pool, sizeof(sek_list));
  list->pool = pool;
  list->cap = 8;
  list->items = (char **)sek_alloc(pool, list->cap * sizeof(char *));
  list->len = 0;
  return list;
}

void sek_list_add(sek_list *list, const char *text) {
  if (list->len == list->cap) {
    size_t cap = list->cap * 2;
    char **items = (char **)sek_alloc(list->pool, cap * sizeof(char *));
    memcpy(items, list->items, list->len * sizeof(char *));
    list->items = items;
    list->cap = cap;
  }

  list->items[list->len] = sek_strdup(list->pool, text);
  list->len++;
}

/* ---- small string helpers ------------------------------------------ */

int sek_empty(const char *text) { return NULL == text || '\0' == text[0]; }

const char *sek_first(const char *a, const char *b) {
  if (!sek_empty(a)) {
    return a;
  }
  if (!sek_empty(b)) {
    return b;
  }
  return "";
}

const char *sek_orempty(const char *text) { return NULL == text ? "" : text; }

int sek_has_prefix(const char *text, const char *prefix) {
  size_t len = strlen(prefix);
  return 0 == strncmp(text, prefix, len);
}

int sek_contains(const char *hay, const char *needle) {
  return NULL != hay && NULL != needle && NULL != strstr(hay, needle);
}

/* One trailing slash removed, and only one - `//` at the end of a
 * configured address is a mistake this library does not try to correct. */
char *sek_trimslash(sek_pool *pool, const char *text) {
  size_t len;

  if (NULL == text) {
    return sek_strdup(pool, "");
  }

  len = strlen(text);
  if (0 < len && '/' == text[len - 1]) {
    return sek_strndup(pool, text, len - 1);
  }

  return sek_strdup(pool, text);
}

/* A url without its query string, for a message that must not leak one.
 * A query here carries the vault path, the secret name or a filter, none
 * of which belongs in a log. */
char *sek_bareurl(sek_pool *pool, const char *url) {
  const char *at = strchr(url, '?');
  return NULL == at ? sek_strdup(pool, url) : sek_strndup(pool, url, (size_t)(at - url));
}

/* ASCII uppercase, deliberately not toupper(): toupper() follows the
 * machine's locale, and in a Turkish locale `i` uppercases to a dotted
 * capital that is not `I` - which would silently give envkey a different
 * answer on one machine than on every other. */
char sek_upper(char ch) {
  if ('a' <= ch && 'z' >= ch) {
    return (char)(ch - 'a' + 'A');
  }
  return ch;
}

char sek_lower(char ch) {
  if ('A' <= ch && 'Z' >= ch) {
    return (char)(ch - 'A' + 'a');
  }
  return ch;
}

char *sek_lowercase(sek_pool *pool, const char *text) {
  char *out = sek_strdup(pool, text);
  size_t index;

  for (index = 0; '\0' != out[index]; index++) {
    out[index] = sek_lower(out[index]);
  }

  return out;
}

/* ---- reading a local file ------------------------------------------ */

/* The one thing the CORE does with the platform beyond the environment,
 * and the reason the line between core and plugin is "reads at most a
 * local file": `dotenv` reads a `.env`, `file` reads a mounted secret
 * directory, and a hashicorp login reads its service-account JWT off the
 * same helper from the plugin side. */
char *sek_readfile(sek_pool *pool, const char *path, int *why) {
  FILE *file = fopen(path, "rb");
  sek_buf out;
  char chunk[8192];
  size_t got;

  *why = 0;

  if (NULL == file) {
    *why = errno;
    return NULL;
  }

  sek_buf_init(&out, pool);
  while (0 < (got = fread(chunk, 1, sizeof(chunk), file))) {
    sek_buf_addn(&out, chunk, got);
  }

  if (0 != ferror(file)) {
    *why = errno;
    fclose(file);
    return NULL;
  }

  fclose(file);

  return out.data;
}

int sek_absent(int why) { return ENOENT == why || ENOTDIR == why; }

const char *sek_first3(const char *a, const char *b, const char *c) {
  if (!sek_empty(a)) {
    return a;
  }
  if (!sek_empty(b)) {
    return b;
  }
  return sek_orempty(c);
}
