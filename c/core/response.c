// Transport response wrapper (mirrors core/response.rs).

#include "sdk.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define PREVIEW_LENGTH 160

static char* dup_str(const char* s) {
  if (!s) s = "";
  size_t n = strlen(s);
  char* d = (char*)malloc(n + 1);
  memcpy(d, s, n + 1);
  return d;
}

Response* response_new(voxgig_value* resmap) {
  Response* r = (Response*)calloc(1, sizeof(Response));

  voxgig_value* status = getp(resmap, "status");
  r->status = v_is_noval(status) ? -1 : to_int(status);

  const char* st = get_str(resmap, "statusText");
  r->status_text = dup_str(st ? st : "");
  r->headers = getp(resmap, "headers");
  r->json = getp(resmap, "json");
  r->body = getp(resmap, "body");
  r->err = NULL;
  bool unreadable = false;
  r->unreadable = get_bool(resmap, "unreadable", &unreadable) && unreadable;
  return r;
}

static const char* header_value(voxgig_value* headers, const char* name) {
  if (v_is_map(headers)) {
    voxgig_map* m = voxgig_as_map(headers);
    for (size_t i = 0; i < m->len; i++) {
      if (strcasecmp(m->entries[i].key, name) == 0 && voxgig_is_string(m->entries[i].value)) {
        return voxgig_as_string(m->entries[i].value);
      }
    }
  }
  return "";
}

static bool names_json(const char* type) {
  for (; *type; type++) {
    if (strncasecmp(type, "json", 4) == 0) return true;
  }
  return false;
}

// Whitespace runs as one space, trimmed. Returns malloc'd.
static char* flatten_space(const char* s) {
  char* out = (char*)malloc(strlen(s) + 1);
  size_t j = 0;
  bool space = false;
  for (; *s; s++) {
    if (isspace((unsigned char)*s)) {
      space = 0 < j;
      continue;
    }
    if (space) {
      out[j++] = ' ';
      space = false;
    }
    out[j++] = *s;
  }
  out[j] = '\0';
  return out;
}

// Cleaned whole: a secret the bound would split could leave its prefix.
static char* body_preview(Context* ctx, voxgig_value* text) {
  char* raw = voxgig_is_string(text) ? dup_str(voxgig_as_string(text)) : voxgig_stringify(text, -1);
  char* spaced = flatten_space(raw);
  char* flat = clean_str(ctx, spaced);
  free(raw);
  free(spaced);
  size_t points = 0;
  for (size_t i = 0; flat[i]; i++) {
    if (((unsigned char)flat[i] & 0xC0) == 0x80) continue;
    if (points == PREVIEW_LENGTH) {
      char* out = (char*)malloc(i + 4);
      memcpy(out, flat, i);
      memcpy(out + i, "...", 4);
      free(flat);
      return out;
    }
    points++;
  }
  return flat;
}

PNError* unreadable_body(Context* ctx, int64_t status, voxgig_value* headers,
                         voxgig_value* text, voxgig_value* sent, PNError* failed) {
  const char* type = header_value(headers, "content-type");
  char* agent = clean_str(ctx, header_value(sent, "user-agent"));
  char* preview = (v_is_noval(text) || v_is_null(text)) ? NULL : body_preview(ctx, text);

  size_t size = strlen(type) + strlen(agent) + (preview ? strlen(preview) : 0) + 128;
  char* detail = (char*)malloc(size);
  snprintf(detail, size, "HTTP %lld, content-type %s, user-agent %s%s%s", (long long)status,
    '\0' == type[0] ? "none" : type, '\0' == agent[0] ? "transport default" : agent,
    preview ? ", body: " : "", preview ? preview : "");
  free(agent);
  free(preview);

  PNError* out = failed;
  size_t n = strlen(type) + strlen(detail) + (failed ? strlen(failed->msg) : 0) + 64;
  char* msg = (char*)malloc(n);
  if (failed) {
    snprintf(msg, n, "%s (%s)", failed->msg, detail);
    free(failed->msg);
    failed->msg = msg;
  } else {
    bool json = '\0' == type[0] || names_json(type);
    if (json) {
      snprintf(msg, n, "response: body is not valid JSON (%s)", detail);
    } else {
      snprintf(msg, n, "response: expected JSON, got %s (%s)", type, detail);
    }
    out = context_make_error(ctx, json ? "response_json_invalid" : "response_content_type", msg);
    free(msg);
  }
  free(detail);
  return out;
}
