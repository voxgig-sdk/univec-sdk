// Audit trail (mirrors feature/audit.rs). Emits a structured record for every
// operation — who (actor), what (entity + op), the outcome, and a correlation
// id — suitable for compliance logging. Records accumulate on the feature
// (bounded by `max`, default 1000) and, when a `sink` callback is supplied,
// are also pushed to it. The actor is the per-call ctrl actor, falling back to
// the options `actor`, then "anonymous". Each operation is audited exactly once
// (the per-context marker in ctx.out prevents a PreDone + PreUnexpected
// double-log). Timestamps use the injectable `now` clock so tests stay
// deterministic.

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

#define AUDIT_SEEN_KEY "audit_seen"

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  int64_t seq;

  // Activity tracking (mirrors the ts client._audit record).
  voxgig_value* records; // List of Value
} AuditFeature;

static void audit_emit(AuditFeature* af, Context* ctx, const char* outcome) {
  if (!af->active) {
    return;
  }

  // One record per operation (PreDone + a following PreUnexpected on a failure
  // must not double-log).
  voxgig_value* seen = ctx_out_extra_get(ctx, AUDIT_SEEN_KEY);
  if (voxgig_is_bool(seen) && voxgig_as_bool(seen)) {
    return;
  }
  ctx_out_extra_set(ctx, AUDIT_SEEN_KEY, v_bool(true));

  af->seq += 1;

  const char* actor = "anonymous";
  const char* opt_actor = fopt_str(af->options, "actor", "");
  if (opt_actor[0] != '\0') {
    actor = opt_actor;
  }
  if (ctx->ctrl && ctx->ctrl->actor && ctx->ctrl->actor[0] != '\0') {
    actor = ctx->ctrl->actor;
  }

  const char* entity = ctx->op->entity;
  const char* opname = ctx->op->name;

  voxgig_value* record = v_map();
  setp(record, "seq", v_num((double)af->seq));
  setp(record, "ts", v_num((double)fopt_now_call(af->options)));
  setp(record, "actor", v_str(actor));
  setp(record, "entity", v_str(entity));
  setp(record, "op", v_str(opname));
  setp(record, "outcome", v_str(outcome));
  setp(record, "correlationId", v_str(ctx->id));
  if (ctx->result) {
    setp(record, "status", v_num((double)ctx->result->status));
  }

  voxgig_list_push(voxgig_as_list(af->records), voxgig_retain(record));
  int64_t max = fopt_int(af->options, "max", 1000);
  while (voxgig_list_len(voxgig_as_list(af->records)) > (size_t)max) {
    voxgig_list_erase(voxgig_as_list(af->records), 0);
  }

  voxgig_value* sink = getp(af->options, "sink");
  if (voxgig_is_func(sink)) {
    call_vfn(sink, record);
  }
}

static void audit_pre_done(AuditFeature* af, Context* ctx) {
  // Outcome reflects the actual result; a non-2xx reaches PreDone before the
  // pipeline errors.
  bool ok = ctx->result ? (ctx->result->ok && ctx->result->err == NULL) : false;
  audit_emit(af, ctx, ok ? "ok" : "error");
}

static void audit_pre_unexpected(AuditFeature* af, Context* ctx) {
  audit_emit(af, ctx, "error");
}

static const char* audit_name(Feature* f) { return ((AuditFeature*)f)->name; }
static bool audit_active(Feature* f) { return ((AuditFeature*)f)->active; }
static voxgig_value* audit_add_options(Feature* f) { return ((AuditFeature*)f)->add_opts; }

static void audit_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)ctx;
  AuditFeature* af = (AuditFeature*)f;
  af->options = options;
  af->active = fopt_bool(options, "active", false);
  af->seq = 0;
}

static void audit_hook(Feature* f, const char* name, Context* ctx) {
  AuditFeature* af = (AuditFeature*)f;
  if (strcmp(name, "PreDone") == 0) {
    audit_pre_done(af, ctx);
  } else if (strcmp(name, "PreUnexpected") == 0) {
    audit_pre_unexpected(af, ctx);
  }
}

static voxgig_value* audit_track(Feature* f) {
  AuditFeature* af = (AuditFeature*)f;
  int64_t n = (int64_t)voxgig_list_len(voxgig_as_list(af->records));
  return cmap(2, "records", v_num((double)n), "seq", v_num((double)af->seq));
}

static const FeatureVT AUDIT_VT = {
  audit_name, audit_active, audit_add_options, audit_init, audit_hook,
  audit_track,
};

Feature* feature_audit_new(void) {
  AuditFeature* af = (AuditFeature*)calloc(1, sizeof(AuditFeature));
  af->base.vt = &AUDIT_VT;
  af->name = strdup("audit");
  af->active = true;
  af->add_opts = NULL;
  af->options = voxgig_new_undef();
  af->seq = 0;
  af->records = voxgig_new_list();
  return (Feature*)af;
}
