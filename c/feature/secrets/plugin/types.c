// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/types.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Errors and the raise mechanism. See types.h for why longjmp. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "types.h"

static CatchFrame *current = NULL;

/* The error the most recent raise parked here. FILE SCOPE ON PURPOSE —
 * see types.h for why it cannot live in the frame. */
static PluginError *pending = NULL;

int plugin_try(CatchFrame *f) {
  f->prev = current;
  current = f;
  pending = NULL;
  return 0;
}

PluginError *plugin_caught(void) {
  return pending;
}

void plugin_end(CatchFrame *f) {
  current = f->prev;
}

/* §12's detail fields, IN THIS FIXED ORDER. The order is part of the
 * contract: an earlier draft named six fields while other sections
 * promised diagnostics with nowhere to go, which would have left each
 * port inventing its own order and breaking message parity. */
static const char *DETAIL_ORDER[] = {
  "host", "ref", "name", "tag", "point", "key", "capability",
  "range", "version", "match", "candidates", "cycle", "holders",
  "refs", "path", "cause", NULL
};

const char *format_error(const char *code, const char *text, Value *details) {
  /* Values render as COMPACT JSON, so a value containing a space or a
   * bracket cannot break the parse and a list renders as an array. The
   * bracket is absent entirely when no field applies. */
  size_t cap = 256;
  if (NULL != text) cap += strlen(text);
  char *tail = (char *)arena_alloc(1);
  tail[0] = '\0';
  size_t taillen = 0;
  size_t tailcap = 1;

  for (int i = 0; NULL != DETAIL_ORDER[i]; i++) {
    const char *k = DETAIL_ORDER[i];
    if (!vhas(details, k)) continue;
    const char *rendered = vjson(vget(details, k));
    size_t need = taillen + strlen(k) + strlen(rendered) + 4;
    if (need + 1 > tailcap) {
      size_t newcap = need * 2 + 16;
      char *grown = (char *)arena_alloc(newcap);
      memcpy(grown, tail, taillen + 1);
      tail = grown;
      tailcap = newcap;
    }
    if (0 < taillen) {
      tail[taillen++] = ' ';
      tail[taillen] = '\0';
    }
    int n = snprintf(tail + taillen, tailcap - taillen, "%s=%s", k, rendered);
    taillen += (size_t)n;
  }

  size_t total = strlen("plugin/") + strlen(code) + 2 +
                 (NULL == text ? 0 : strlen(text)) + taillen + 8;
  char *out = (char *)arena_alloc(total);
  if (0 < taillen) {
    snprintf(out, total, "plugin/%s: %s [%s]", code,
             NULL == text ? "" : text, tail);
  }
  else {
    snprintf(out, total, "plugin/%s: %s", code, NULL == text ? "" : text);
  }
  (void)cap;
  return out;
}

void fail(const char *code, const char *text, Value *details) {
  PluginError *e = (PluginError *)arena_alloc(sizeof(PluginError));
  e->code = arena_strdup(code);
  e->text = arena_strdup(NULL == text ? "" : text);
  e->details = NULL == details ? vmap() : details;
  e->message = format_error(code, text, e->details);

  if (NULL == current) {
    /* No catch frame: the caller could not have checked, so saying so
     * loudly beats returning into code that will use a bad value. */
    fprintf(stderr, "plugin: uncaught %s\n", e->message);
    exit(70);
  }

  CatchFrame *f = current;
  current = f->prev;
  pending = e;
  longjmp(f->jmp, 1);
}

Value *details1(const char *k, Value *v) {
  Value *d = vmap();
  vset(d, k, v);
  return d;
}

Value *details2(const char *k1, Value *v1, const char *k2, Value *v2) {
  Value *d = vmap();
  vset(d, k1, v1);
  vset(d, k2, v2);
  return d;
}

Value *plugin_merge(Value *a, Value *b) {
  if (!vismap(a) || !vismap(b)) return NULL == b ? a : b;
  Value *out = vmap();
  const char **keys;
  size_t n = vkeys(a, &keys);
  for (size_t i = 0; i < n; i++) vset(out, keys[i], vget(a, keys[i]));
  n = vkeys(b, &keys);
  for (size_t i = 0; i < n; i++) {
    Value *bv = vget(b, keys[i]);
    Value *av = vget(out, keys[i]);
    if (vismap(av) && vismap(bv)) vset(out, keys[i], plugin_merge(av, bv));
    else vset(out, keys[i], bv);
  }
  return out;
}

bool matchvalue(Value *want, Value *have) {
  if (visnull(want)) return true;
  if (vismap(want)) {
    if (!vismap(have)) return false;
    const char **keys;
    size_t n = vkeys(want, &keys);
    for (size_t i = 0; i < n; i++) {
      if (!vhas(have, keys[i])) return false;
      if (!matchvalue(vget(want, keys[i]), vget(have, keys[i]))) return false;
    }
    return true;
  }
  return vsame(want, have);
}
