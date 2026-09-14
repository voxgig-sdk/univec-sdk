// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (c/src/ref.c)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Identity: name+tag (§4). */

#include <stdio.h>
#include <string.h>

#include "ref.h"

#define MAX_REF 1024

static bool isnamehead(char c) {
  return ('a' <= c && 'z' >= c) || ('A' <= c && 'Z' >= c) || '@' == c;
}

static bool isnamebody(char c) {
  return ('a' <= c && 'z' >= c) || ('A' <= c && 'Z' >= c) ||
         ('0' <= c && '9' >= c) ||
         '.' == c || '~' == c || '_' == c || '-' == c || '/' == c;
}

static bool istagchar(char c) {
  return ('a' <= c && 'z' >= c) || ('A' <= c && 'Z' >= c) ||
         ('0' <= c && '9' >= c) ||
         '.' == c || '~' == c || '_' == c || '-' == c;
}

static bool checkname_s(const char *name) {
  if (NULL == name) return false;
  size_t n = strlen(name);
  if (0 == n || MAX_REF < n) return false;
  if (!isnamehead(name[0])) return false;
  for (size_t i = 1; i < n; i++) {
    if (!isnamebody(name[i])) return false;
  }
  return true;
}

static bool checktag_s(const char *tag) {
  if (NULL == tag) return false;
  size_t n = strlen(tag);
  /* The empty tag is an ordinary tag (§4 rule 2). The single-instance
   * case writes no tag and never learns tags exist. */
  if (0 == n) return true;
  if (MAX_REF < n) return false;
  for (size_t i = 0; i < n; i++) {
    if (!istagchar(tag[i])) return false;
  }
  return true;
}

bool checkname(Value *name) {
  /* A non-string is not a name. Every port has to answer this the same
   * way, and `ref/name` pins it for numbers, nulls and maps alike. */
  if (!visstr(name)) return false;
  return checkname_s(vasstr(name));
}

bool checktag(Value *tag) {
  if (!visstr(tag)) return false;
  return checktag_s(vasstr(tag));
}

Value *parseref(Value *str) {
  if (!visstr(str)) {
    fail("plugin_bad_name", "ref must be a string", NULL);
  }
  const char *s = vasstr(str);

  /* Split on the FIRST `$`. Nothing in the grammar decides this — `$` is
   * in neither character class — so the corpus is the arbiter (§4 rule
   * 5), and it picks the split that blames the part actually at fault:
   * `a$b$c` is a good name with a bad tag, not the reverse. */
  const char *cut = strchr(s, '$');
  const char *name;
  const char *tag;
  if (NULL == cut) {
    name = arena_strdup(s);
    tag = "";
  }
  else {
    name = arena_strndup(s, (size_t)(cut - s));
    tag = arena_strdup(cut + 1);
  }

  if (!checkname_s(name)) {
    char *text = (char *)arena_alloc(strlen(name) + 32);
    snprintf(text, strlen(name) + 32, "invalid plugin name: %s", name);
    fail("plugin_bad_name", text, details1("name", vstr(name)));
  }
  if (!checktag_s(tag)) {
    char *text = (char *)arena_alloc(strlen(tag) + 32);
    snprintf(text, strlen(tag) + 32, "invalid plugin tag: %s", tag);
    fail("plugin_bad_tag", text,
         details2("name", vstr(name), "tag", vstr(tag)));
  }

  Value *out = vmap();
  vset(out, "name", vstr(name));
  vset(out, "tag", vstr(tag));
  return out;
}

const char *formatref(Value *name, Value *tag) {
  const char *t = visnull(tag) ? "" : (visstr(tag) ? vasstr(tag) : NULL);

  if (!checkname(name)) {
    const char *n = visstr(name) ? vasstr(name) : "";
    size_t sz = strlen(n) + 32;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "invalid plugin name: %s", n);
    fail("plugin_bad_name", text,
         details1("name", visnull(name) ? vnull() : name));
  }
  if (NULL == t || !checktag_s(t)) {
    const char *shown = NULL == t ? "" : t;
    size_t sz = strlen(shown) + 32;
    char *text = (char *)arena_alloc(sz);
    snprintf(text, sz, "invalid plugin tag: %s", shown);
    fail("plugin_bad_tag", text,
         details2("name", name, "tag", visnull(tag) ? vstr("") : tag));
  }

  if ('\0' == t[0]) return arena_strdup(vasstr(name));

  const char *n = vasstr(name);
  size_t sz = strlen(n) + strlen(t) + 2;
  char *out = (char *)arena_alloc(sz);
  snprintf(out, sz, "%s$%s", n, t);
  return out;
}

const char *canonref(Value *str) {
  Value *r = parseref(str);
  return formatref(vget(r, "name"), vget(r, "tag"));
}

const char *tryref(const char *str) {
  if (NULL == str) return NULL;
  const char *cut = strchr(str, '$');
  const char *name;
  const char *tag;
  if (NULL == cut) {
    name = str;
    tag = "";
  }
  else {
    name = arena_strndup(str, (size_t)(cut - str));
    tag = cut + 1;
  }
  if (!checkname_s(name) || !checktag_s(tag)) return NULL;
  if ('\0' == tag[0]) return arena_strdup(name);
  size_t sz = strlen(name) + strlen(tag) + 2;
  char *out = (char *)arena_alloc(sz);
  snprintf(out, sz, "%s$%s", name, tag);
  return out;
}

const char *canon(const char *str) {
  const char *out = tryref(str);
  return NULL == out ? str : out;
}

const char *refname(const char *str) {
  if (NULL == str) return str;
  const char *cut = strchr(str, '$');
  const char *name = NULL == cut ? str : arena_strndup(str, (size_t)(cut - str));
  return checkname_s(name) ? name : str;
}
