// Endpoint point description (mirrors core/point.rs).

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

Point* point_new(voxgig_value* altmap) {
  Point* p = (Point*)calloc(1, sizeof(Point));

  voxgig_value* args = to_map(getp(altmap, "args"));
  p->args = voxgig_is_map(args) ? args : cmap(1, "params", v_list());

  voxgig_value* rename = to_map(getp(altmap, "rename"));
  p->rename = voxgig_is_map(rename) ? rename : cmap(1, "params", v_map());

  voxgig_value* parts = getp(altmap, "parts");
  p->parts = voxgig_is_list(parts) ? parts : voxgig_new_list();

  voxgig_value* params = getp(altmap, "params");
  p->params = voxgig_is_list(params) ? params : voxgig_new_undef();

  voxgig_value* alias = to_map(getp(altmap, "alias"));
  p->alias = voxgig_is_map(alias) ? alias : voxgig_new_map();

  voxgig_value* transform = to_map(getp(altmap, "transform"));
  p->transform = voxgig_is_map(transform) ? transform : voxgig_new_map();

  const char* method = get_str(altmap, "method");
  p->method = dup_str(method ? method : "");
  const char* orig = get_str(altmap, "orig");
  p->orig = dup_str(orig ? orig : "");

  p->select = to_map(getp(altmap, "select"));
  // Absent in config means ACTIVE: emission drops `active: true` as a default (sdkgen L0), so only an explicit `active: false` turns a point off.
  bool active = true;
  get_bool(altmap, "active", &active);
  p->active = active;
  p->relations = getp(altmap, "relations");

  return p;
}
