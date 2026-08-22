// BaseFeature: the no-op feature every hook defaults to (mirrors
// feature/base.rs). Establishes the concrete-feature layout: a struct whose
// first member is `Feature base` (holding the vtable pointer), followed by
// feature-specific state.

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts; // NULL when none
} BaseFeature;

static const char* base_name(Feature* f) { return ((BaseFeature*)f)->name; }
static bool base_active(Feature* f) { return ((BaseFeature*)f)->active; }
static voxgig_value* base_add_options(Feature* f) { return ((BaseFeature*)f)->add_opts; }
static void base_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)f; (void)ctx; (void)options;
}
static void base_hook(Feature* f, const char* name, Context* ctx) {
  (void)f; (void)name; (void)ctx;
}

static const FeatureVT BASE_VT = {
  base_name, base_active, base_add_options, base_init, base_hook,
  NULL, // no activity tracking
};

Feature* feature_base_new(void) {
  BaseFeature* b = (BaseFeature*)calloc(1, sizeof(BaseFeature));
  b->base.vt = &BASE_VT;
  b->name = strdup("base");
  b->active = true;
  b->add_opts = NULL;
  return (Feature*)b;
}
