// Structured hook logging (mirrors feature/log.rs), stderr lines. Logs every
// pipeline hook with operation + spec summary when active; `level` filters.

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  int64_t level;
} LogFeature;

static int64_t level_num(const char* level) {
  if (strcmp(level, "debug") == 0) return 10;
  if (strcmp(level, "warn") == 0) return 30;
  if (strcmp(level, "error") == 0) return 40;
  return 20; // info
}

static const char* log_name(Feature* f) { return ((LogFeature*)f)->name; }
static bool log_active(Feature* f) { return ((LogFeature*)f)->active; }
static voxgig_value* log_add_options(Feature* f) { return ((LogFeature*)f)->add_opts; }

static void log_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)ctx;
  LogFeature* lf = (LogFeature*)f;
  lf->options = options;
  lf->active = fopt_bool(options, "active", false);
  lf->level = level_num(fopt_str(options, "level", "info"));
}

static void loghook(LogFeature* lf, const char* hook, Context* ctx) {
  if (!lf->active) return;
  if (level_num("info") < lf->level) return;

  const char* opname = ctx->op->name;
  char specinfo[256];
  specinfo[0] = '\0';
  if (ctx->spec) {
    snprintf(specinfo, sizeof(specinfo), "%s %s", ctx->spec->method, ctx->spec->path);
  }
  fprintf(stderr, "name=log hook=%s op=%s spec=%s\n", hook, opname, specinfo);
}

static void log_hook(Feature* f, const char* name, Context* ctx) {
  LogFeature* lf = (LogFeature*)f;
  static const char* HOOKS[] = {
    "PostConstruct", "PostConstructEntity", "SetData", "GetData", "SetMatch",
    "GetMatch", "PrePoint", "PreSpec", "PreRequest", "PreResponse", "PreResult", NULL,
  };
  for (int i = 0; HOOKS[i]; i++) {
    if (strcmp(HOOKS[i], name) == 0) {
      loghook(lf, name, ctx);
      return;
    }
  }
}

static const FeatureVT LOG_VT = {
  log_name, log_active, log_add_options, log_init, log_hook,
  NULL, // no activity tracking
};

Feature* feature_log_new(void) {
  LogFeature* lf = (LogFeature*)calloc(1, sizeof(LogFeature));
  lf->base.vt = &LOG_VT;
  lf->name = strdup("log");
  lf->active = false;
  lf->add_opts = NULL;
  lf->options = voxgig_new_undef();
  lf->level = level_num("info");
  return (Feature*)lf;
}
