// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/src/json.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* sekreto's own JSON.
 *
 * There is no JSON in the C standard library and there is no third-party
 * dependency to reach for, so this is the whole of it: a six-case value
 * model, a recursive-descent parser, and a compact writer.
 *
 * Two properties are load-bearing and neither is incidental.
 *
 * A PARSE FAILURE IS NOT `null`. sek_json_parse answers NULL for text
 * that is not JSON and a SEK_JSON_NULL node for the literal `null`;
 * fetchjson needs exactly that difference, because only the first means
 * the store could not answer coherently.
 *
 * OBJECTS ARE INSERTION-ORDERED. A payload's field order is signed by
 * SigV4, and the shared spec compares whole maps, so a re-ordering
 * container would fail both.
 *
 * A port of typescript/src/Json.ts, which is canonical.
 */

#define _POSIX_C_SOURCE 200809L

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

/* A response body arrives before any trust check has been made, so
 * `[[[[[...` must not be able to overflow the stack. */
#define MAXDEPTH 128

sek_json *sek_json_null(sek_pool *pool) {
  sek_json *val = (sek_json *)sek_alloc(pool, sizeof(sek_json));
  val->type = SEK_JSON_NULL;
  return val;
}

sek_json *sek_json_bool(sek_pool *pool, int flag) {
  sek_json *val = (sek_json *)sek_alloc(pool, sizeof(sek_json));
  val->type = SEK_JSON_BOOL;
  val->boolval = 0 != flag;
  return val;
}

sek_json *sek_json_num(sek_pool *pool, double num) {
  sek_json *val = (sek_json *)sek_alloc(pool, sizeof(sek_json));
  val->type = SEK_JSON_NUM;
  val->numval = num;
  return val;
}

sek_json *sek_json_str(sek_pool *pool, const char *text) {
  sek_json *val = (sek_json *)sek_alloc(pool, sizeof(sek_json));
  val->type = SEK_JSON_STR;
  val->strval = sek_strdup(pool, NULL == text ? "" : text);
  return val;
}

sek_json *sek_json_arr(sek_pool *pool) {
  sek_json *val = (sek_json *)sek_alloc(pool, sizeof(sek_json));
  val->type = SEK_JSON_ARR;
  val->itemcap = 8;
  val->items = (sek_json **)sek_alloc(pool, val->itemcap * sizeof(sek_json *));
  return val;
}

sek_json *sek_json_obj(sek_pool *pool) {
  sek_json *val = (sek_json *)sek_alloc(pool, sizeof(sek_json));
  val->type = SEK_JSON_OBJ;
  val->mapcap = 8;
  val->keys = (char **)sek_alloc(pool, val->mapcap * sizeof(char *));
  val->vals = (sek_json **)sek_alloc(pool, val->mapcap * sizeof(sek_json *));
  return val;
}

/* The pool a node was made from is not recorded on the node, so growth
 * needs one handed in; every call site has it. */
static void pushitem(sek_pool *pool, sek_json *arr, sek_json *item) {
  if (arr->itemlen == arr->itemcap) {
    size_t cap = arr->itemcap * 2;
    sek_json **items = (sek_json **)sek_alloc(pool, cap * sizeof(sek_json *));
    memcpy(items, arr->items, arr->itemlen * sizeof(sek_json *));
    arr->items = items;
    arr->itemcap = cap;
  }
  arr->items[arr->itemlen] = item;
  arr->itemlen++;
}

static void setkey(sek_pool *pool, sek_json *obj, const char *key, sek_json *val) {
  size_t index;

  for (index = 0; index < obj->maplen; index++) {
    if (0 == strcmp(obj->keys[index], key)) {
      obj->vals[index] = val;
      return;
    }
  }

  if (obj->maplen == obj->mapcap) {
    size_t cap = obj->mapcap * 2;
    char **keys = (char **)sek_alloc(pool, cap * sizeof(char *));
    sek_json **vals = (sek_json **)sek_alloc(pool, cap * sizeof(sek_json *));
    memcpy(keys, obj->keys, obj->maplen * sizeof(char *));
    memcpy(vals, obj->vals, obj->maplen * sizeof(sek_json *));
    obj->keys = keys;
    obj->vals = vals;
    obj->mapcap = cap;
  }

  obj->keys[obj->maplen] = sek_strdup(pool, key);
  obj->vals[obj->maplen] = val;
  obj->maplen++;
}

/* The pool is passed rather than stored on every node: a node is 100-odd
 * bytes and there are a lot of them in a Doppler config download, and a
 * hidden global would make two Sekretos in two threads share a pool they
 * never agreed to share. */
void sek_json_push(sek_pool *pool, sek_json *arr, sek_json *item) {
  pushitem(pool, arr, item);
}

void sek_json_set(sek_pool *pool, sek_json *obj, const char *key, sek_json *val) {
  setkey(pool, obj, key, val);
}

/* ---- reads --------------------------------------------------------- */

const char *sek_json_asstr(const sek_json *val) {
  if (NULL == val || SEK_JSON_STR != val->type) {
    return NULL;
  }
  return val->strval;
}

const sek_json *sek_json_asarr(const sek_json *val) {
  if (NULL == val || SEK_JSON_ARR != val->type) {
    return NULL;
  }
  return val;
}

const sek_json *sek_json_asobj(const sek_json *val) {
  if (NULL == val || SEK_JSON_OBJ != val->type) {
    return NULL;
  }
  return val;
}

static sek_json *getkey(const sek_json *obj, const char *key) {
  size_t index;

  if (NULL == obj || SEK_JSON_OBJ != obj->type) {
    return NULL;
  }

  for (index = 0; index < obj->maplen; index++) {
    if (0 == strcmp(obj->keys[index], key)) {
      return obj->vals[index];
    }
  }

  return NULL;
}

sek_json *sek_json_dig(sek_json *val, ...) {
  va_list keys;
  sek_json *at = val;

  va_start(keys, val);

  for (;;) {
    const char *key = va_arg(keys, const char *);
    if (NULL == key) {
      break;
    }
    at = getkey(at, key);
    if (NULL == at) {
      break;
    }
  }

  va_end(keys);

  return at;
}

const char *sek_json_text(sek_pool *pool, const sek_json *val) {
  if (NULL == val) {
    return NULL;
  }

  switch (val->type) {
  case SEK_JSON_STR:
    return val->strval;
  case SEK_JSON_NUM:
    return sek_numstr(pool, val->numval);
  case SEK_JSON_BOOL:
    return val->boolval ? "true" : "false";
  /* A JSON null is the absence of a value, so it must not become the
   * string "null" - a null field in a vault response is a MISS. */
  case SEK_JSON_NULL:
  default:
    return NULL;
  }
}

/* ---- numbers ------------------------------------------------------- */

char *sek_numstr(sek_pool *pool, double val) {
  char buf[64];

  /* JSON has no infinity and no NaN; a non-finite value can only have
   * come from arithmetic this library should not have done. */
  if (isnan(val) || isinf(val)) {
    return sek_strdup(pool, "null");
  }

  /* An integral value prints as an integer, so a JSON `1` round-trips as
   * `1` rather than `1.0` - the CLI's output line and the spec's map
   * comparisons both depend on it. */
  if (val == (double)(long long)val && 9007199254740992.0 > (val < 0 ? -val : val)) {
    snprintf(buf, sizeof(buf), "%lld", (long long)val);
    return sek_strdup(pool, buf);
  }

  snprintf(buf, sizeof(buf), "%.17g", val);
  return sek_strdup(pool, buf);
}

/* ---- writer -------------------------------------------------------- */

char *sek_json_quote(sek_pool *pool, const char *text) {
  sek_buf out;
  size_t index;

  sek_buf_init(&out, pool);
  sek_buf_addch(&out, '"');

  for (index = 0; NULL != text && '\0' != text[index]; index++) {
    unsigned char ch = (unsigned char)text[index];

    switch (ch) {
    case '"':
      sek_buf_add(&out, "\\\"");
      break;
    case '\\':
      sek_buf_add(&out, "\\\\");
      break;
    case '\n':
      sek_buf_add(&out, "\\n");
      break;
    case '\r':
      sek_buf_add(&out, "\\r");
      break;
    case '\t':
      sek_buf_add(&out, "\\t");
      break;
    default:
      if (0x20 > ch) {
        sek_buf_addfmt(&out, "\\u%04x", (unsigned)ch);
      } else {
        /* Non-ASCII is not escaped: the bytes are already UTF-8 and
         * escaping them would need surrogate arithmetic no port does. */
        sek_buf_addch(&out, (char)ch);
      }
      break;
    }
  }

  sek_buf_addch(&out, '"');

  return out.data;
}

static void writeval(sek_buf *out, const sek_json *val) {
  size_t index;

  if (NULL == val) {
    sek_buf_add(out, "null");
    return;
  }

  switch (val->type) {
  case SEK_JSON_NULL:
    sek_buf_add(out, "null");
    break;
  case SEK_JSON_BOOL:
    sek_buf_add(out, val->boolval ? "true" : "false");
    break;
  case SEK_JSON_NUM:
    sek_buf_add(out, sek_numstr(out->pool, val->numval));
    break;
  case SEK_JSON_STR:
    sek_buf_add(out, sek_json_quote(out->pool, val->strval));
    break;
  case SEK_JSON_ARR:
    sek_buf_addch(out, '[');
    for (index = 0; index < val->itemlen; index++) {
      if (0 < index) {
        sek_buf_addch(out, ',');
      }
      writeval(out, val->items[index]);
    }
    sek_buf_addch(out, ']');
    break;
  case SEK_JSON_OBJ:
    sek_buf_addch(out, '{');
    for (index = 0; index < val->maplen; index++) {
      if (0 < index) {
        sek_buf_addch(out, ',');
      }
      sek_buf_add(out, sek_json_quote(out->pool, val->keys[index]));
      sek_buf_addch(out, ':');
      writeval(out, val->vals[index]);
    }
    sek_buf_addch(out, '}');
    break;
  default:
    sek_buf_add(out, "null");
    break;
  }
}

char *sek_json_stringify(sek_pool *pool, const sek_json *val) {
  sek_buf out;
  sek_buf_init(&out, pool);
  writeval(&out, val);
  return out.data;
}

/* ---- parser -------------------------------------------------------- */

typedef struct {
  sek_pool *pool;
  const char *text;
  size_t len;
  size_t at;
  int bad;
  int depth;
} reader;

static sek_json *readvalue(reader *rd);

static void skipspace(reader *rd) {
  while (rd->at < rd->len) {
    char ch = rd->text[rd->at];
    if (' ' == ch || '\t' == ch || '\n' == ch || '\r' == ch) {
      rd->at++;
    } else {
      break;
    }
  }
}

/* A word matched WHOLE, not by its first letter: `nullish` is not null. */
static int readword(reader *rd, const char *word) {
  size_t len = strlen(word);

  if (rd->len - rd->at < len) {
    return 0;
  }
  if (0 != strncmp(rd->text + rd->at, word, len)) {
    return 0;
  }

  rd->at += len;
  return 1;
}

/* One UTF-16 code unit as UTF-8. No surrogate-pair recombination, in this
 * port or any other: a lone surrogate is written as-is, which keeps every
 * port byte-identical on an input none of them should ever see. */
static void addunit(sek_buf *out, unsigned code) {
  if (0x80 > code) {
    sek_buf_addch(out, (char)code);
  } else if (0x800 > code) {
    sek_buf_addch(out, (char)(0xC0 | (code >> 6)));
    sek_buf_addch(out, (char)(0x80 | (code & 0x3F)));
  } else {
    sek_buf_addch(out, (char)(0xE0 | (code >> 12)));
    sek_buf_addch(out, (char)(0x80 | ((code >> 6) & 0x3F)));
    sek_buf_addch(out, (char)(0x80 | (code & 0x3F)));
  }
}

static int hexdigit(char ch) {
  if ('0' <= ch && '9' >= ch) {
    return ch - '0';
  }
  if ('a' <= ch && 'f' >= ch) {
    return ch - 'a' + 10;
  }
  if ('A' <= ch && 'F' >= ch) {
    return ch - 'A' + 10;
  }
  return -1;
}

static char *readstring(reader *rd) {
  sek_buf out;

  if (rd->at >= rd->len || '"' != rd->text[rd->at]) {
    rd->bad = 1;
    return NULL;
  }
  rd->at++;

  sek_buf_init(&out, rd->pool);

  while (rd->at < rd->len) {
    char ch = rd->text[rd->at];

    if ('"' == ch) {
      rd->at++;
      return out.data;
    }

    if ('\\' == ch) {
      rd->at++;
      if (rd->at >= rd->len) {
        break;
      }
      ch = rd->text[rd->at];
      rd->at++;

      switch (ch) {
      case '"':
        sek_buf_addch(&out, '"');
        break;
      case '\\':
        sek_buf_addch(&out, '\\');
        break;
      case '/':
        sek_buf_addch(&out, '/');
        break;
      case 'b':
        sek_buf_addch(&out, '\b');
        break;
      case 'f':
        sek_buf_addch(&out, '\f');
        break;
      case 'n':
        sek_buf_addch(&out, '\n');
        break;
      case 'r':
        sek_buf_addch(&out, '\r');
        break;
      case 't':
        sek_buf_addch(&out, '\t');
        break;
      case 'u': {
        unsigned code = 0;
        int step;
        if (rd->len - rd->at < 4) {
          rd->bad = 1;
          return NULL;
        }
        for (step = 0; step < 4; step++) {
          int digit = hexdigit(rd->text[rd->at + (size_t)step]);
          if (0 > digit) {
            rd->bad = 1;
            return NULL;
          }
          code = (code << 4) | (unsigned)digit;
        }
        rd->at += 4;
        addunit(&out, code);
        break;
      }
      default:
        rd->bad = 1;
        return NULL;
      }

      continue;
    }

    sek_buf_addch(&out, ch);
    rd->at++;
  }

  rd->bad = 1;
  return NULL;
}

static sek_json *readnumber(reader *rd) {
  size_t start = rd->at;
  char *span;
  char *stop = NULL;
  double num;

  if (rd->at < rd->len && '-' == rd->text[rd->at]) {
    rd->at++;
  }

  while (rd->at < rd->len) {
    char ch = rd->text[rd->at];
    if (('0' <= ch && '9' >= ch) || '.' == ch || 'e' == ch || 'E' == ch || '+' == ch ||
        '-' == ch) {
      rd->at++;
    } else {
      break;
    }
  }

  if (start == rd->at) {
    rd->bad = 1;
    return NULL;
  }

  span = sek_strndup(rd->pool, rd->text + start, rd->at - start);
  num = strtod(span, &stop);

  if (NULL == stop || '\0' != *stop) {
    rd->bad = 1;
    return NULL;
  }

  /* `1e999` parses to infinity, which JSON cannot express and which would
   * later blow up a token-expiry computation. */
  if (isnan(num) || isinf(num)) {
    rd->bad = 1;
    return NULL;
  }

  return sek_json_num(rd->pool, num);
}

static sek_json *readarray(reader *rd) {
  sek_json *out = sek_json_arr(rd->pool);

  rd->at++; /* [ */
  skipspace(rd);

  if (rd->at < rd->len && ']' == rd->text[rd->at]) {
    rd->at++;
    return out;
  }

  for (;;) {
    sek_json *item = readvalue(rd);
    if (rd->bad) {
      return NULL;
    }

    pushitem(rd->pool, out, item);
    skipspace(rd);

    if (rd->at >= rd->len) {
      rd->bad = 1;
      return NULL;
    }

    if (',' == rd->text[rd->at]) {
      rd->at++;
      continue;
    }

    if (']' == rd->text[rd->at]) {
      rd->at++;
      return out;
    }

    rd->bad = 1;
    return NULL;
  }
}

static sek_json *readobject(reader *rd) {
  sek_json *out = sek_json_obj(rd->pool);

  rd->at++; /* { */
  skipspace(rd);

  if (rd->at < rd->len && '}' == rd->text[rd->at]) {
    rd->at++;
    return out;
  }

  for (;;) {
    char *key;
    sek_json *val;

    skipspace(rd);
    key = readstring(rd);
    if (rd->bad) {
      return NULL;
    }

    skipspace(rd);
    if (rd->at >= rd->len || ':' != rd->text[rd->at]) {
      rd->bad = 1;
      return NULL;
    }
    rd->at++;

    val = readvalue(rd);
    if (rd->bad) {
      return NULL;
    }

    setkey(rd->pool, out, key, val);
    skipspace(rd);

    if (rd->at >= rd->len) {
      rd->bad = 1;
      return NULL;
    }

    if (',' == rd->text[rd->at]) {
      rd->at++;
      continue;
    }

    if ('}' == rd->text[rd->at]) {
      rd->at++;
      return out;
    }

    rd->bad = 1;
    return NULL;
  }
}

static sek_json *readvalue(reader *rd) {
  char head;

  if (MAXDEPTH < rd->depth) {
    rd->bad = 1;
    return NULL;
  }

  skipspace(rd);

  if (rd->at >= rd->len) {
    rd->bad = 1;
    return NULL;
  }

  head = rd->text[rd->at];

  if ('{' == head || '[' == head) {
    sek_json *out;
    rd->depth++;
    out = '{' == head ? readobject(rd) : readarray(rd);
    rd->depth--;
    return out;
  }

  if ('"' == head) {
    char *text = readstring(rd);
    if (rd->bad) {
      return NULL;
    }
    return sek_json_str(rd->pool, text);
  }

  if ('t' == head) {
    if (readword(rd, "true")) {
      return sek_json_bool(rd->pool, 1);
    }
    rd->bad = 1;
    return NULL;
  }

  if ('f' == head) {
    if (readword(rd, "false")) {
      return sek_json_bool(rd->pool, 0);
    }
    rd->bad = 1;
    return NULL;
  }

  if ('n' == head) {
    if (readword(rd, "null")) {
      return sek_json_null(rd->pool);
    }
    rd->bad = 1;
    return NULL;
  }

  return readnumber(rd);
}

sek_json *sek_json_parse(sek_pool *pool, const char *text) {
  reader rd;
  sek_json *out;

  if (NULL == text) {
    return NULL;
  }

  rd.pool = pool;
  rd.text = text;
  rd.len = strlen(text);
  rd.at = 0;
  rd.bad = 0;
  rd.depth = 0;

  out = readvalue(&rd);

  if (rd.bad) {
    return NULL;
  }

  /* Trailing content after the top-level value is not JSON. */
  skipspace(&rd);
  if (rd.at != rd.len) {
    return NULL;
  }

  return out;
}
