// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/value.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The dynamic value and the JSON reader. See value.h for why the arena
 * is the design rather than a shortcut. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "value.h"

/* --- arena ---------------------------------------------------------- */

/* A chain of blocks. Big allocations get their own block rather than
 * rounding the block size up, so one long string cannot waste a block. */
typedef struct Block {
  struct Block *next;
  size_t used;
  size_t size;
  char *data;
} Block;

#define BLOCK_MIN (64 * 1024)

static Block *arena_head = NULL;

static void arena_die(void) {
  fprintf(stderr, "plugin: out of memory\n");
  exit(70);
}

void *arena_alloc(size_t size) {
  /* Align to 16, so a Value or a double placed here is aligned. */
  size = (size + 15u) & ~((size_t)15u);

  if (NULL == arena_head || arena_head->used + size > arena_head->size) {
    size_t want = size > BLOCK_MIN ? size : BLOCK_MIN;
    Block *b = (Block *)calloc(1, sizeof(Block));
    if (NULL == b) arena_die();
    b->data = (char *)calloc(1, want);
    if (NULL == b->data) arena_die();
    b->size = want;
    b->used = 0;
    b->next = arena_head;
    arena_head = b;
  }

  void *p = arena_head->data + arena_head->used;
  arena_head->used += size;
  return p;
}

char *arena_strndup(const char *s, size_t n) {
  char *out = (char *)arena_alloc(n + 1);
  if (NULL != s && 0 < n) memcpy(out, s, n);
  out[n] = '\0';
  return out;
}

char *arena_strdup(const char *s) {
  return arena_strndup(s, NULL == s ? 0 : strlen(s));
}

void arena_reset(void) {
  Block *b = arena_head;
  while (NULL != b) {
    Block *next = b->next;
    free(b->data);
    free(b);
    b = next;
  }
  arena_head = NULL;
}

/* --- construction --------------------------------------------------- */

static Value *vnew(VKind kind) {
  Value *v = (Value *)arena_alloc(sizeof(Value));
  v->kind = kind;
  return v;
}

Value *vnull(void) { return vnew(VNULL); }

Value *vbool(bool b) {
  Value *v = vnew(VBOOL);
  v->boolean = b;
  return v;
}

Value *vnum(double n) {
  Value *v = vnew(VNUM);
  v->num = n;
  return v;
}

Value *vstr(const char *s) {
  Value *v = vnew(VSTR);
  v->str = arena_strdup(NULL == s ? "" : s);
  return v;
}

Value *vlist(void) {
  Value *v = vnew(VLIST);
  v->cap = 8;
  v->items = (Value **)arena_alloc(sizeof(Value *) * v->cap);
  v->len = 0;
  return v;
}

Value *vmap(void) { return vnew(VMAP); }

/* --- access --------------------------------------------------------- */

bool visnull(const Value *v) { return NULL == v || VNULL == v->kind; }
bool vismap(const Value *v) { return NULL != v && VMAP == v->kind; }
bool vislist(const Value *v) { return NULL != v && VLIST == v->kind; }
bool visstr(const Value *v) { return NULL != v && VSTR == v->kind; }
bool visnum(const Value *v) { return NULL != v && VNUM == v->kind; }
bool visbool(const Value *v) { return NULL != v && VBOOL == v->kind; }

static VEntry *ventry(const Value *m, const char *key) {
  if (!vismap(m) || NULL == key) return NULL;
  for (VEntry *e = m->first; NULL != e; e = e->next) {
    if (0 == strcmp(e->key, key)) return e;
  }
  return NULL;
}

Value *vget(const Value *m, const char *key) {
  VEntry *e = ventry(m, key);
  return NULL == e ? NULL : e->val;
}

bool vhas(const Value *m, const char *key) {
  return NULL != ventry(m, key);
}

void vset(Value *m, const char *key, Value *val) {
  if (!vismap(m)) return;
  VEntry *e = ventry(m, key);
  if (NULL != e) {
    e->val = val;
    return;
  }
  e = (VEntry *)arena_alloc(sizeof(VEntry));
  e->key = arena_strdup(key);
  e->val = val;
  e->next = NULL;
  if (NULL == m->first) {
    m->first = e;
    m->last = e;
  }
  else {
    m->last->next = e;
    m->last = e;
  }
}

void vdel(Value *m, const char *key) {
  if (!vismap(m) || NULL == key) return;
  VEntry *prev = NULL;
  for (VEntry *e = m->first; NULL != e; e = e->next) {
    if (0 == strcmp(e->key, key)) {
      if (NULL == prev) m->first = e->next;
      else prev->next = e->next;
      if (m->last == e) m->last = prev;
      return;
    }
    prev = e;
  }
}

Value *vat(const Value *l, size_t i) {
  if (!vislist(l) || i >= l->len) return NULL;
  return l->items[i];
}

void vpush(Value *l, Value *item) {
  if (!vislist(l)) return;
  if (l->len == l->cap) {
    size_t cap = l->cap * 2;
    Value **items = (Value **)arena_alloc(sizeof(Value *) * cap);
    memcpy(items, l->items, sizeof(Value *) * l->len);
    l->items = items;
    l->cap = cap;
  }
  l->items[l->len++] = item;
}

size_t vlen(const Value *v) {
  if (vislist(v)) return v->len;
  if (vismap(v)) {
    size_t n = 0;
    for (VEntry *e = v->first; NULL != e; e = e->next) n++;
    return n;
  }
  return 0;
}

const char *vasstr(const Value *v) { return visstr(v) ? v->str : NULL; }
double vasnum(const Value *v) { return visnum(v) ? v->num : 0.0; }
bool vasbool(const Value *v) { return visbool(v) ? v->boolean : false; }

size_t vkeys(const Value *m, const char ***out) {
  size_t n = vlen(m);
  const char **keys = (const char **)arena_alloc(sizeof(char *) * (n + 1));
  size_t i = 0;
  if (vismap(m)) {
    for (VEntry *e = m->first; NULL != e; e = e->next) keys[i++] = e->key;
  }
  *out = keys;
  return i;
}

static int cmpstr(const void *a, const void *b) {
  return strcmp(*(const char **)a, *(const char **)b);
}

size_t vsortedkeys(const Value *m, const char ***out) {
  size_t n = vkeys(m, out);
  if (1 < n) qsort((void *)*out, n, sizeof(char *), cmpstr);
  return n;
}

bool vtruthy(const Value *v) {
  if (NULL == v) return false;
  switch (v->kind) {
    case VNULL: return false;
    case VBOOL: return v->boolean;
    /* §4 rule 4: JSON truthiness. 0 and "" are FALSE, matching every
     * other port's `truthy`, not C's "any nonzero scalar". */
    case VNUM: return 0.0 != v->num;
    case VSTR: return '\0' != v->str[0];
    default: return true;
  }
}

bool vsame(const Value *a, const Value *b) {
  bool anull = visnull(a), bnull = visnull(b);
  if (anull || bnull) return anull && bnull;
  /* TYPE FIRST. `true` and `1` are different values, and
   * `capability/match` is the entry that says so. */
  if (a->kind != b->kind) return false;
  switch (a->kind) {
    case VBOOL: return a->boolean == b->boolean;
    case VNUM: return a->num == b->num;
    case VSTR: return 0 == strcmp(a->str, b->str);
    case VLIST: {
      if (a->len != b->len) return false;
      for (size_t i = 0; i < a->len; i++) {
        if (!vsame(a->items[i], b->items[i])) return false;
      }
      return true;
    }
    case VMAP: {
      if (vlen(a) != vlen(b)) return false;
      for (VEntry *e = a->first; NULL != e; e = e->next) {
        if (!vhas(b, e->key)) return false;
        if (!vsame(e->val, vget(b, e->key))) return false;
      }
      return true;
    }
    default: return true;
  }
}

Value *vclone(const Value *v) {
  if (NULL == v) return NULL;
  switch (v->kind) {
    case VNULL: return vnull();
    case VBOOL: return vbool(v->boolean);
    case VNUM: return vnum(v->num);
    case VSTR: return vstr(v->str);
    case VLIST: {
      Value *out = vlist();
      for (size_t i = 0; i < v->len; i++) vpush(out, vclone(v->items[i]));
      return out;
    }
    case VMAP: {
      Value *out = vmap();
      for (VEntry *e = v->first; NULL != e; e = e->next) {
        vset(out, e->key, vclone(e->val));
      }
      return out;
    }
    default: return vnull();
  }
}

/* --- a growable output buffer, for json ----------------------------- */

typedef struct {
  char *data;
  size_t len;
  size_t cap;
} Buf;

static void bufinit(Buf *b) {
  b->cap = 256;
  b->data = (char *)arena_alloc(b->cap);
  b->len = 0;
  b->data[0] = '\0';
}

static void bufgrow(Buf *b, size_t need) {
  if (b->len + need + 1 <= b->cap) return;
  size_t cap = b->cap;
  while (cap < b->len + need + 1) cap *= 2;
  char *data = (char *)arena_alloc(cap);
  memcpy(data, b->data, b->len);
  b->data = data;
  b->cap = cap;
}

static void bufputn(Buf *b, const char *s, size_t n) {
  bufgrow(b, n);
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = '\0';
}

static void bufputs(Buf *b, const char *s) { bufputn(b, s, strlen(s)); }
static void bufputc(Buf *b, char c) { bufputn(b, &c, 1); }

/* --- json out ------------------------------------------------------- */

const char *vnumstr(double n) {
  char tmp[64];
  /* An integral double renders as an integer: the corpus's expected
   * values are written `1`, not `1.0`, and a port that emits the latter
   * fails every comparison for a reason that has nothing to do with the
   * behaviour under test. */
  if (isfinite(n) && n == (double)(long long)n) {
    snprintf(tmp, sizeof(tmp), "%lld", (long long)n);
  }
  else {
    snprintf(tmp, sizeof(tmp), "%.17g", n);
  }
  return arena_strdup(tmp);
}

static void jsonstr(Buf *b, const char *s) {
  bufputc(b, '"');
  for (const unsigned char *p = (const unsigned char *)s; '\0' != *p; p++) {
    switch (*p) {
      case '"': bufputs(b, "\\\""); break;
      case '\\': bufputs(b, "\\\\"); break;
      case '\n': bufputs(b, "\\n"); break;
      case '\r': bufputs(b, "\\r"); break;
      case '\t': bufputs(b, "\\t"); break;
      case '\b': bufputs(b, "\\b"); break;
      case '\f': bufputs(b, "\\f"); break;
      default:
        if (0x20 > *p) {
          char esc[8];
          snprintf(esc, sizeof(esc), "\\u%04x", *p);
          bufputs(b, esc);
        }
        else {
          bufputc(b, (char)*p);
        }
    }
  }
  bufputc(b, '"');
}

static void jsonval(Buf *b, const Value *v) {
  if (visnull(v)) { bufputs(b, "null"); return; }
  switch (v->kind) {
    case VBOOL: bufputs(b, v->boolean ? "true" : "false"); break;
    case VNUM: bufputs(b, vnumstr(v->num)); break;
    case VSTR: jsonstr(b, v->str); break;
    case VLIST: {
      bufputc(b, '[');
      for (size_t i = 0; i < v->len; i++) {
        if (0 < i) bufputc(b, ',');
        jsonval(b, v->items[i]);
      }
      bufputc(b, ']');
      break;
    }
    case VMAP: {
      /* SORTED keys, so two `vsame` values render identically. */
      const char **keys;
      size_t n = vsortedkeys(v, &keys);
      bufputc(b, '{');
      for (size_t i = 0; i < n; i++) {
        if (0 < i) bufputc(b, ',');
        jsonstr(b, keys[i]);
        bufputc(b, ':');
        jsonval(b, vget(v, keys[i]));
      }
      bufputc(b, '}');
      break;
    }
    default: bufputs(b, "null");
  }
}

const char *vjson(const Value *v) {
  Buf b;
  bufinit(&b);
  jsonval(&b, v);
  return b.data;
}

/* --- json in -------------------------------------------------------- */

typedef struct {
  const char *s;
  size_t i;
  size_t n;
  const char *err;
} Parser;

static Value *parseval(Parser *p);

static void skipws(Parser *p) {
  while (p->i < p->n) {
    char c = p->s[p->i];
    if (' ' == c || '\t' == c || '\n' == c || '\r' == c) p->i++;
    else break;
  }
}

static bool lit(Parser *p, const char *word) {
  size_t n = strlen(word);
  if (p->i + n <= p->n && 0 == strncmp(p->s + p->i, word, n)) {
    p->i += n;
    return true;
  }
  return false;
}

/* One UTF-16 code unit as UTF-8, surrogate pairs included — the corpus
 * is ASCII today, and a parser that mangles the first non-ASCII string
 * anyone adds is a trap rather than a simplification. */
static void pututf8(Buf *b, unsigned int cp) {
  if (0x80 > cp) {
    bufputc(b, (char)cp);
  }
  else if (0x800 > cp) {
    bufputc(b, (char)(0xC0 | (cp >> 6)));
    bufputc(b, (char)(0x80 | (cp & 0x3F)));
  }
  else if (0x10000 > cp) {
    bufputc(b, (char)(0xE0 | (cp >> 12)));
    bufputc(b, (char)(0x80 | ((cp >> 6) & 0x3F)));
    bufputc(b, (char)(0x80 | (cp & 0x3F)));
  }
  else {
    bufputc(b, (char)(0xF0 | (cp >> 18)));
    bufputc(b, (char)(0x80 | ((cp >> 12) & 0x3F)));
    bufputc(b, (char)(0x80 | ((cp >> 6) & 0x3F)));
    bufputc(b, (char)(0x80 | (cp & 0x3F)));
  }
}

static int hex4(Parser *p) {
  if (p->i + 4 > p->n) return -1;
  int out = 0;
  for (int k = 0; k < 4; k++) {
    char c = p->s[p->i + (size_t)k];
    int d;
    if ('0' <= c && '9' >= c) d = c - '0';
    else if ('a' <= c && 'f' >= c) d = c - 'a' + 10;
    else if ('A' <= c && 'F' >= c) d = c - 'A' + 10;
    else return -1;
    out = out * 16 + d;
  }
  p->i += 4;
  return out;
}

static const char *parsestr(Parser *p) {
  if (p->i >= p->n || '"' != p->s[p->i]) { p->err = "expected string"; return NULL; }
  p->i++;
  Buf b;
  bufinit(&b);
  while (p->i < p->n) {
    char c = p->s[p->i];
    if ('"' == c) { p->i++; return b.data; }
    if ('\\' == c) {
      p->i++;
      if (p->i >= p->n) break;
      char e = p->s[p->i++];
      switch (e) {
        case '"': bufputc(&b, '"'); break;
        case '\\': bufputc(&b, '\\'); break;
        case '/': bufputc(&b, '/'); break;
        case 'n': bufputc(&b, '\n'); break;
        case 't': bufputc(&b, '\t'); break;
        case 'r': bufputc(&b, '\r'); break;
        case 'b': bufputc(&b, '\b'); break;
        case 'f': bufputc(&b, '\f'); break;
        case 'u': {
          int hi = hex4(p);
          if (0 > hi) { p->err = "bad \\u escape"; return NULL; }
          unsigned int cp = (unsigned int)hi;
          if (0xD800 <= cp && 0xDBFF >= cp && p->i + 1 < p->n &&
              '\\' == p->s[p->i] && 'u' == p->s[p->i + 1]) {
            p->i += 2;
            int lo = hex4(p);
            if (0 > lo) { p->err = "bad \\u escape"; return NULL; }
            cp = 0x10000 + ((cp - 0xD800) << 10) + ((unsigned int)lo - 0xDC00);
          }
          pututf8(&b, cp);
          break;
        }
        default: p->err = "bad escape"; return NULL;
      }
      continue;
    }
    bufputc(&b, c);
    p->i++;
  }
  p->err = "unterminated string";
  return NULL;
}

static Value *parseval(Parser *p) {
  skipws(p);
  if (p->i >= p->n) { p->err = "unexpected end"; return NULL; }

  char c = p->s[p->i];

  if ('n' == c) {
    if (lit(p, "null")) return vnull();
    p->err = "bad literal"; return NULL;
  }
  if ('t' == c) {
    if (lit(p, "true")) return vbool(true);
    p->err = "bad literal"; return NULL;
  }
  if ('f' == c) {
    if (lit(p, "false")) return vbool(false);
    p->err = "bad literal"; return NULL;
  }
  if ('"' == c) {
    const char *s = parsestr(p);
    return NULL == s ? NULL : vstr(s);
  }
  if ('[' == c) {
    p->i++;
    Value *out = vlist();
    skipws(p);
    if (p->i < p->n && ']' == p->s[p->i]) { p->i++; return out; }
    for (;;) {
      Value *item = parseval(p);
      if (NULL == item) return NULL;
      vpush(out, item);
      skipws(p);
      if (p->i >= p->n) { p->err = "unterminated array"; return NULL; }
      if (',' == p->s[p->i]) { p->i++; continue; }
      if (']' == p->s[p->i]) { p->i++; return out; }
      p->err = "expected , or ]";
      return NULL;
    }
  }
  if ('{' == c) {
    p->i++;
    Value *out = vmap();
    skipws(p);
    if (p->i < p->n && '}' == p->s[p->i]) { p->i++; return out; }
    for (;;) {
      skipws(p);
      const char *key = parsestr(p);
      if (NULL == key) return NULL;
      skipws(p);
      if (p->i >= p->n || ':' != p->s[p->i]) { p->err = "expected :"; return NULL; }
      p->i++;
      Value *val = parseval(p);
      if (NULL == val) return NULL;
      vset(out, key, val);
      skipws(p);
      if (p->i >= p->n) { p->err = "unterminated object"; return NULL; }
      if (',' == p->s[p->i]) { p->i++; continue; }
      if ('}' == p->s[p->i]) { p->i++; return out; }
      p->err = "expected , or }";
      return NULL;
    }
  }

  if ('-' == c || ('0' <= c && '9' >= c)) {
    /* JSON's number grammar is STRICT, and §9.5 makes that observable:
     * env values "parse as JSON, falling back to string", so anything
     * this reader accepts loosely silently becomes a number where the
     * canonical keeps the authored string. `1e`, `1.`, `01`, `.5` and a
     * bare `-` are all errors to JSON.parse; only `-0` and `1e5` are
     * not.
     *
     *   number = [ '-' ] int [ frac ] [ exp ]
     *   int    = '0' | digit1-9 *digit
     *   frac   = '.' 1*digit
     *   exp    = ('e'|'E') [ '+' | '-' ] 1*digit
     */
    size_t start = p->i;
    if ('-' == p->s[p->i]) p->i++;
    if (p->i >= p->n) { p->err = "bad number"; return NULL; }
    if ('0' == p->s[p->i]) {
      p->i++;
    }
    else if ('1' <= p->s[p->i] && '9' >= p->s[p->i]) {
      while (p->i < p->n && '0' <= p->s[p->i] && '9' >= p->s[p->i]) p->i++;
    }
    else { p->err = "bad number"; return NULL; }
    if (p->i < p->n && '.' == p->s[p->i]) {
      p->i++;
      size_t d = p->i;
      while (p->i < p->n && '0' <= p->s[p->i] && '9' >= p->s[p->i]) p->i++;
      if (d == p->i) { p->err = "bad number"; return NULL; }
    }
    if (p->i < p->n && ('e' == p->s[p->i] || 'E' == p->s[p->i])) {
      p->i++;
      if (p->i < p->n && ('+' == p->s[p->i] || '-' == p->s[p->i])) p->i++;
      size_t d = p->i;
      while (p->i < p->n && '0' <= p->s[p->i] && '9' >= p->s[p->i]) p->i++;
      if (d == p->i) { p->err = "bad number"; return NULL; }
    }
    char *text = arena_strndup(p->s + start, p->i - start);
    return vnum(strtod(text, NULL));
  }

  p->err = "unexpected character";
  return NULL;
}

Value *vparse(const char *text, const char **err) {
  Parser p;
  p.s = text;
  p.i = 0;
  p.n = strlen(text);
  p.err = NULL;

  Value *v = parseval(&p);
  if (NULL == v) {
    if (NULL != err) *err = NULL == p.err ? "parse failed" : p.err;
    return NULL;
  }
  skipws(&p);
  if (p.i != p.n) {
    if (NULL != err) *err = "trailing content";
    return NULL;
  }
  return v;
}
