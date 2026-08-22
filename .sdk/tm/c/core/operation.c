// Operation description (mirrors core/operation.rs).

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

// get_str-or-default filtering empty strings, as rust filter(|s| !s.is_empty()).
static char* get_str_ne(voxgig_value* m, const char* key, const char* def) {
  const char* s = get_str(m, key);
  if (s && s[0] != '\0') return dup_str(s);
  return dup_str(def);
}

Operation* operation_new(voxgig_value* opmap) {
  Operation* o = (Operation*)calloc(1, sizeof(Operation));
  o->entity = get_str_ne(opmap, "entity", "_");
  o->name = get_str_ne(opmap, "name", "_");
  o->input = get_str_ne(opmap, "input", "_");

  voxgig_value* points = getp(opmap, "points");
  o->points = voxgig_is_list(points) ? points : voxgig_new_list();

  o->alias = to_map(getp(opmap, "alias"));
  return o;
}
