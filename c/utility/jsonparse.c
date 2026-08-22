// JSON parse bridge — wraps the vendored struct JSON parser.

#include "sdk.h"

#include <string.h>

voxgig_value* json_parse(const char* text) {
  if (!text) return voxgig_new_undef();
  voxgig_value* v = voxgig_parse_json(text, strlen(text));
  return v ? v : voxgig_new_undef();
}
