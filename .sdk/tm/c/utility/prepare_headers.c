// prepare_headers utility (mirrors utility/prepare_headers.rs).

#include "sdk.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bool same_name(const char* a, const char* b) {
  for (; *a && *b; a++, b++) {
    if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return false;
  }
  return *a == *b;
}

// Appends a part to a joined string, growing it.
static void join_part(char** text, size_t* len, const char* sep, const char* part) {
  size_t plen = strlen(part);
  size_t slen = 0 < *len ? strlen(sep) : 0;
  char* grown = (char*)realloc(*text, *len + slen + plen + 1);
  if (slen) memcpy(grown + *len, sep, slen);
  memcpy(grown + *len + slen, part, plen);
  *len += slen + plen;
  grown[*len] = '\0';
  *text = grown;
}

// Strips the blanks around a cookie piece, in place.
static char* trim_blank(char* s) {
  while (isspace((unsigned char)*s)) s++;
  size_t n = strlen(s);
  while (0 < n && isspace((unsigned char)s[n - 1])) s[--n] = '\0';
  return s;
}

static bool same_text(const char* name, const char* text, size_t len) {
  return strlen(name) == len && 0 == strncmp(name, text, len);
}

// Whether a cookie the caller sends has a name a cookie argument sends: a
// map's own keys as the pair sends them, percent-encoded, else the
// argument's wire name.
static bool sent_named(const char* name, size_t nlen, void* ud) {
  voxgig_list* cargs = (voxgig_list*)ud;
  for (size_t i = 0; i < cargs->len; i++) {
    voxgig_list* arg = voxgig_as_list(cargs->items[i]);
    voxgig_value* val = arg->items[2];
    if (v_is_noval(val) || v_is_null(val)) continue;
    if (voxgig_is_map(val)) {
      voxgig_strvec keys = voxgig_keysof(val);
      bool found = false;
      for (size_t k = 0; k < keys.len && !found; k++) {
        voxgig_value* kv = voxgig_new_string(keys.data[k]);
        char* key = voxgig_escurl(kv);
        found = same_text(key, name, nlen);
        free(key);
        voxgig_release(kv);
      }
      voxgig_strvec_free(&keys);
      if (found) return true;
    } else if (same_text(voxgig_as_string(arg->items[1]), name, nlen)) {
      return true;
    }
  }
  return false;
}

// A value's text, percent-encoded, as a new string.
static char* esc_text(voxgig_value* val) {
  char* text = voxgig_stringify(val, -1);
  voxgig_value* sv = voxgig_new_string(text);
  char* out = voxgig_escurl(sv);
  voxgig_release(sv);
  free(text);
  return out;
}

static char* name_value(const char* name, const char* value) {
  size_t len = strlen(name) + 1 + strlen(value);
  char* pair = (char*)malloc(len + 1);
  snprintf(pair, len + 1, "%s=%s", name, value);
  return pair;
}

// Whether a cookie's name, blanks aside, is one the predicate owns.
static bool cookie_named(const char* cookie, bool (*named)(const char* name, size_t nlen, void* ud), void* ud) {
  size_t nlen = strcspn(cookie, "=");
  while (0 < nlen && isspace((unsigned char)cookie[nlen - 1])) nlen--;
  return named(cookie, nlen, ud);
}

// The caller's cookie pieces with the owned cookies removed, "; "-joined and
// malloc'd, or NULL when none is kept: a cookie is one ;-delimited piece,
// whatever its value holds.
char* cookie_keep(const char* header, bool (*named)(const char* name, size_t nlen, void* ud), void* ud) {
  char* joined = NULL;
  size_t jlen = 0;
  const char* text = header;
  while ('\0' != *text) {
    size_t plen = strcspn(text, ";");
    char* piece = (char*)malloc(plen + 1);
    memcpy(piece, text, plen);
    piece[plen] = '\0';
    char* cookie = trim_blank(piece);
    if ('\0' != *cookie && !cookie_named(cookie, named, ud)) join_part(&joined, &jlen, "; ", cookie);
    free(piece);
    text += plen + (';' == text[plen] ? 1 : 0);
  }
  return joined;
}

// The form style of a cookie parameter: a list repeats the name, a map sends
// its own keys, and every value is percent-encoded.
static char* cookie_pair(const char* wire, voxgig_value* val) {
  char* joined = NULL;
  size_t jlen = 0;
  if (voxgig_is_list(val)) {
    voxgig_list* items = voxgig_as_list(val);
    for (size_t i = 0; i < items->len; i++) {
      char* text = esc_text(items->items[i]);
      char* pair = name_value(wire, text);
      join_part(&joined, &jlen, "; ", pair);
      free(pair);
      free(text);
    }
  } else if (voxgig_is_map(val)) {
    voxgig_strvec keys = voxgig_keysof(val);
    for (size_t i = 0; i < keys.len; i++) {
      voxgig_value* kv = voxgig_new_string(keys.data[i]);
      char* name = voxgig_escurl(kv);
      voxgig_release(kv);
      char* text = esc_text(getp(val, keys.data[i]));
      char* pair = name_value(name, text);
      join_part(&joined, &jlen, "; ", pair);
      free(pair);
      free(text);
      free(name);
    }
    voxgig_strvec_free(&keys);
  } else {
    char* text = esc_text(val);
    joined = name_value(wire, text);
    free(text);
  }
  if (NULL == joined) {
    joined = (char*)malloc(1);
    joined[0] = '\0';
  }
  return joined;
}

voxgig_value* prepare_headers_util(Context* ctx) {
  voxgig_value* options = ctx->client ? sdk_options_map(ctx->client) : ctx->options;

  voxgig_value* headers = getp(options, "headers");
  voxgig_value* out = NULL;
  if (!v_is_noval(headers) && !v_is_null(headers)) {
    voxgig_value* cloned = voxgig_clone(headers);
    if (voxgig_is_map(cloned)) out = cloned;
  }
  if (NULL == out) out = voxgig_new_map();
  media_headers(ctx->point, out);

  // A header argument replaces a default of the same name, whatever its case.
  voxgig_value* hargs = call_args(ctx, "header");
  voxgig_list* hl = voxgig_as_list(hargs);
  for (size_t i = 0; i < hl->len; i++) {
    voxgig_list* arg = voxgig_as_list(hl->items[i]);
    const char* wire = voxgig_as_string(arg->items[1]);
    voxgig_value* val = arg->items[2];
    if (v_is_noval(val) || v_is_null(val)) continue;

    size_t n = strlen(wire);
    char* key = (char*)malloc(n + 1);
    for (size_t k = 0; k < n; k++) key[k] = (char)tolower((unsigned char)wire[k]);
    key[n] = '\0';
    voxgig_map* om = voxgig_as_map(out);
    for (size_t j = om->len; j > 0; j--) {
      if (same_name(om->entries[j - 1].key, key)) {
        voxgig_value* dk = voxgig_new_string(om->entries[j - 1].key);
        voxgig_delprop(out, dk);
        voxgig_release(dk);
      }
    }
    char* text = voxgig_stringify(val, -1);
    setp(out, key, voxgig_new_string_take(text, strlen(text)));
    free(key);
  }
  voxgig_release(hargs);

  // A cookie argument travels in the cookie header, form serialized and
  // percent-encoded, replacing a cookie of the same name among those the
  // caller's headers already send.
  voxgig_value* cargs = call_args(ctx, "cookie");
  voxgig_list* cl = voxgig_as_list(cargs);
  bool any = false;
  for (size_t i = 0; i < cl->len; i++) {
    voxgig_value* val = voxgig_as_list(cl->items[i])->items[2];
    if (!v_is_noval(val) && !v_is_null(val)) any = true;
  }
  if (any) {
    char* joined = NULL;
    size_t jlen = 0;
    voxgig_map* om = voxgig_as_map(out);
    for (size_t j = om->len; j > 0; j--) {
      if (!same_name(om->entries[j - 1].key, "cookie")) continue;
      voxgig_value* given = om->entries[j - 1].value;
      if (voxgig_is_string(given)) {
        char* rest = cookie_keep(voxgig_as_string(given), sent_named, cl);
        if (NULL != rest) {
          join_part(&joined, &jlen, "; ", rest);
          free(rest);
        }
      }
      voxgig_value* dk = voxgig_new_string(om->entries[j - 1].key);
      voxgig_delprop(out, dk);
      voxgig_release(dk);
    }
    for (size_t i = 0; i < cl->len; i++) {
      voxgig_list* arg = voxgig_as_list(cl->items[i]);
      voxgig_value* val = arg->items[2];
      if (v_is_noval(val) || v_is_null(val)) continue;
      char* pair = cookie_pair(voxgig_as_string(arg->items[1]), val);
      if ('\0' != *pair) join_part(&joined, &jlen, "; ", pair);
      free(pair);
    }
    if (NULL != joined) setp(out, "cookie", voxgig_new_string_take(joined, jlen));
  }
  voxgig_release(cargs);

  return out;
}
