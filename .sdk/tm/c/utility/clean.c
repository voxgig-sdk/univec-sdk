// clean utility (mirrors utility/clean.rs — go clean returns value unchanged).

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

voxgig_value* clean_util(Context* ctx, voxgig_value* val) {
  (void)ctx;
  return val;
}

char* clean_str(Context* ctx, const char* val) {
  (void)ctx;
  if (!val) val = "";
  size_t n = strlen(val);
  char* d = (char*)malloc(n + 1);
  memcpy(d, val, n + 1);
  return d;
}
