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

  // A log line leaves the pipeline, so it carries the cleaned record: the
  // spec after auth holds the credential, and a logger serialises whatever
  // it is handed.
  voxgig_value* record = clean_util(ctx, cmap(4,
    "hook", v_str(hook),
    "op", cmap(2, "entity", v_str(ctx->op->entity), "name", v_str(opname)),
    "spec", ctx->spec ? spec_to_value(ctx->spec) : voxgig_new_undef(),
    "ctx", context_to_value(ctx)));

  voxgig_value* logger = getp(lf->options, "logger");
  if (voxgig_is_func(logger)) {
    call_vfn(logger, record);
    return;
  }

  char specinfo[256];
  specinfo[0] = '\0';
  voxgig_value* spec = getp(record, "spec");
  if (voxgig_is_map(spec)) {
    const char* method = get_str(spec, "method");
    const char* path = get_str(spec, "path");
    snprintf(specinfo, sizeof(specinfo), "%s %s", method ? method : "", path ? path : "");
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
