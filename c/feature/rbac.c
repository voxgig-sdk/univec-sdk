// Client-side role/permission enforcement (mirrors feature/rbac.rs). Before
// an operation resolves its endpoint, the required permission for that
// entity+operation is checked against the permissions the client holds; a
// disallowed call is short-circuited with an `rbac_denied` error (via
// ctx.out point, which make_point surfaces) and never touches the network.
// Required permissions come from `rules` (keyed by `<entity>.<op>`, `<op>`,
// or `*`); the default when no rule matches is controlled by `deny` (default:
// allow when unspecified). Held permissions are the `permissions` list (a `*`
// grants everything).

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
  voxgig_value* granted; // Map of permission string -> bool(true)

  // Activity tracking (mirrors the ts client._rbac record).
  int64_t allowed;
  int64_t denied;
  voxgig_value* last;
} RbacFeature;

// The entity name for the current op: the resolved entity when present, else
// the operation's declared entity.
static const char* rbac_entity_name(Context* ctx) {
  if (ctx->entity) return ctx->entity->vt->get_name(ctx->entity);
  return ctx->op->entity;
}

// Look up the required permission for this operation. Returns true and fills
// `out` when a rule matches (checking `<entity>.<op>`, `<op>`, then `*`).
static bool rbac_required(RbacFeature* rf, Context* ctx, char* out, size_t outsz) {
  voxgig_value* rules = fopt_map(rf->options, "rules");
  if (!voxgig_is_map(rules)) return false;

  const char* entity = rbac_entity_name(ctx);
  const char* opname = ctx->op->name;

  char k0[512];
  snprintf(k0, sizeof(k0), "%s.%s", entity, opname);
  const char* keys[3] = {k0, opname, "*"};
  for (int i = 0; i < 3; i++) {
    const char* r = get_str(rules, keys[i]);
    if (r) {
      snprintf(out, outsz, "%s", r);
      return true;
    }
  }
  return false;
}

static bool rbac_granted_has(RbacFeature* rf, const char* key) {
  voxgig_value* v = getp(rf->granted, key);
  return voxgig_is_bool(v) && voxgig_as_bool(v);
}

static void rbac_track(RbacFeature* rf, Context* ctx, const char* required, bool allowed) {
  if (allowed) {
    rf->allowed += 1;
  } else {
    rf->denied += 1;
  }
  const char* opname = ctx->op->name;
  voxgig_value* last = v_map();
  setp(last, "required", v_str(required));
  setp(last, "allowed", v_bool(allowed));
  setp(last, "op", v_str(opname));
  rf->last = last;
}

static void rbac_reject(RbacFeature* rf, Context* ctx, const char* required) {
  rbac_track(rf, ctx, required, false);

  const char* opname = ctx->op->name;
  if (opname[0] == '\0') opname = "?";

  char msg[640];
  snprintf(msg, sizeof(msg), "Permission \"%s\" required for operation \"%s\"", required,
           opname);
  PNError* err = context_make_error(ctx, "rbac_denied", msg);

  // Short-circuit endpoint resolution; make_point surfaces this error before
  // any network activity.
  ctx_out_set_point_err(ctx, err);
}

static void rbac_pre_point(RbacFeature* rf, Context* ctx) {
  if (!rf->active) return;

  char required[512];
  if (!rbac_required(rf, ctx, required, sizeof(required))) {
    // No rule: honour the default policy.
    if (fopt_bool(rf->options, "deny", false)) {
      rbac_reject(rf, ctx, "<default-deny>");
    }
    return;
  }

  if (rbac_granted_has(rf, "*") || rbac_granted_has(rf, required)) {
    rbac_track(rf, ctx, required, true);
    return;
  }

  rbac_reject(rf, ctx, required);
}

static const char* rbac_name(Feature* f) { return ((RbacFeature*)f)->name; }
static bool rbac_active(Feature* f) { return ((RbacFeature*)f)->active; }
static voxgig_value* rbac_add_options(Feature* f) { return ((RbacFeature*)f)->add_opts; }

static void rbac_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)ctx;
  RbacFeature* rf = (RbacFeature*)f;
  rf->options = options;
  rf->active = fopt_bool(options, "active", false);

  rf->granted = v_map();
  voxgig_value* perms = fopt_list(options, "permissions");
  if (voxgig_is_list(perms)) {
    voxgig_list* l = voxgig_as_list(perms);
    for (size_t i = 0; i < l->len; i++) {
      if (voxgig_is_string(l->items[i])) {
        setp(rf->granted, voxgig_as_string(l->items[i]), v_bool(true));
      }
    }
  }
}

static void rbac_hook(Feature* f, const char* name, Context* ctx) {
  RbacFeature* rf = (RbacFeature*)f;
  if (strcmp(name, "PrePoint") == 0) {
    rbac_pre_point(rf, ctx);
  }
}

static voxgig_value* rbac_track_snapshot(Feature* f) {
  RbacFeature* rf = (RbacFeature*)f;
  return cmap(2, "allowed", v_num((double)rf->allowed),
              "denied", v_num((double)rf->denied));
}

static const FeatureVT RBAC_VT = {
  rbac_name, rbac_active, rbac_add_options, rbac_init, rbac_hook,
  rbac_track_snapshot,
};

Feature* feature_rbac_new(void) {
  RbacFeature* rf = (RbacFeature*)calloc(1, sizeof(RbacFeature));
  rf->base.vt = &RBAC_VT;
  rf->name = strdup("rbac");
  rf->active = true; // matches rust new() (overridden by init from options)
  rf->add_opts = NULL;
  rf->options = voxgig_new_undef();
  rf->granted = voxgig_new_map();
  rf->allowed = 0;
  rf->denied = 0;
  rf->last = voxgig_new_undef();
  return (Feature*)rf;
}
