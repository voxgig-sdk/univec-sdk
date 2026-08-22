// Request specification (mirrors core/spec.rs).

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

static char* dup_str(const char* s) {
  if (!s) s = "";
  size_t n = strlen(s);
  char* d = (char*)malloc(n + 1);
  memcpy(d, s, n + 1);
  return d;
}

static void set_str(char** slot, const char* s) {
  free(*slot);
  *slot = dup_str(s);
}

void spec_set_step(Spec* s, const char* v) { set_str(&s->step, v); }
void spec_set_method(Spec* s, const char* v) { set_str(&s->method, v); }
void spec_set_url(Spec* s, const char* v) { set_str(&s->url, v); }
void spec_set_path(Spec* s, const char* v) { set_str(&s->path, v); }

Spec* spec_new(voxgig_value* specmap) {
  Spec* s = (Spec*)calloc(1, sizeof(Spec));
  s->parts = voxgig_new_undef();
  s->headers = voxgig_new_map();
  s->alias = voxgig_new_map();
  s->base = dup_str("");
  s->prefix = dup_str("");
  s->suffix = dup_str("");
  s->params = voxgig_new_map();
  s->query = voxgig_new_map();
  s->step = dup_str("");
  s->method = dup_str("GET");
  s->body = voxgig_new_undef();
  s->url = dup_str("");
  s->path = dup_str("");

  if (!voxgig_is_map(specmap)) return s;

  voxgig_value* parts = getp(specmap, "parts");
  if (voxgig_is_list(parts)) s->parts = parts;
  voxgig_value* headers = getp(specmap, "headers");
  if (voxgig_is_map(headers)) s->headers = headers;
  voxgig_value* alias = getp(specmap, "alias");
  if (voxgig_is_map(alias)) s->alias = alias;

  const char* b = get_str(specmap, "base");
  if (b) set_str(&s->base, b);
  const char* pr = get_str(specmap, "prefix");
  if (pr) set_str(&s->prefix, pr);
  const char* sf = get_str(specmap, "suffix");
  if (sf) set_str(&s->suffix, sf);

  voxgig_value* params = getp(specmap, "params");
  if (voxgig_is_map(params)) s->params = params;
  voxgig_value* query = getp(specmap, "query");
  if (voxgig_is_map(query)) s->query = query;

  const char* st = get_str(specmap, "step");
  if (st) set_str(&s->step, st);
  const char* m = get_str(specmap, "method");
  if (m) set_str(&s->method, m);

  voxgig_value* body = getp(specmap, "body");
  if (!v_is_noval(body)) s->body = body;

  const char* u = get_str(specmap, "url");
  if (u) set_str(&s->url, u);
  const char* p = get_str(specmap, "path");
  if (p) set_str(&s->path, p);

  return s;
}

voxgig_value* spec_to_value(Spec* s) {
  voxgig_value* out = voxgig_new_map();
  setp(out, "base", v_str(s->base));
  setp(out, "prefix", v_str(s->prefix));
  setp(out, "suffix", v_str(s->suffix));
  setp(out, "path", v_str(s->path));
  setp(out, "method", v_str(s->method));
  setp(out, "params", v_share(s->params));
  setp(out, "query", v_share(s->query));
  setp(out, "headers", v_share(s->headers));
  setp(out, "step", v_str(s->step));
  setp(out, "alias", v_share(s->alias));
  if (!v_is_noval(s->body)) setp(out, "body", v_share(s->body));
  if (s->url[0] != '\0') setp(out, "url", v_str(s->url));
  return out;
}
