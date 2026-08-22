// Per-call control state (mirrors core/control.rs).

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

Control* control_new(void) {
  Control* c = (Control*)calloc(1, sizeof(Control));
  c->has_throw = false;
  c->throw_v = false;
  c->err = NULL;
  c->explain = voxgig_new_undef();
  c->actor = (char*)calloc(1, 1);
  c->paging = voxgig_new_undef();
  return c;
}

bool control_has_explain(Control* c) { return c && voxgig_is_map(c->explain); }
