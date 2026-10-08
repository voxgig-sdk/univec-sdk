// make_point utility (mirrors utility/make_point.rs). Honours a PrePoint
// short-circuit (rbac stores an error in ctx.out point).

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static voxgig_value* get_elem_i(voxgig_value* list, int64_t i) {
  voxgig_value* k = v_int(i);
  voxgig_value* r = voxgig_getelem(list, k, NULL);
  voxgig_release(k);
  return r ? r : voxgig_new_undef();
}

// How many path segments a point has.
static size_t parts_len(voxgig_value* point) {
  voxgig_value* parts = getp(point, "parts");
  return voxgig_is_list(parts) ? voxgig_as_list(parts)->len : 0;
}

// Does this point's path end in a parameter? A record route ends in the
// record's identifier (/boards/{id}); a cross-reference that also returns
// the entity ends in the relationship's name (/posts/{id}/author). That,
// then fewest segments, is what tells the entity's own route from a
// cross-reference. The same rule runs at generation time, in
// helpers/opShape.ts — both sides must move together.
static bool terminal_param(voxgig_value* point) {
  voxgig_value* parts = getp(point, "parts");
  if (!voxgig_is_list(parts)) return false;
  voxgig_list* pl = voxgig_as_list(parts);
  if (0 == pl->len) return false;
  voxgig_value* last = pl->items[pl->len - 1];
  if (!voxgig_is_string(last)) return false;
  const char* s = voxgig_as_string(last);
  return NULL != s && '{' == s[0];
}

static voxgig_value* own_point(voxgig_value* points) {
  voxgig_list* pl = voxgig_as_list(points);
  voxgig_value* best = pl->items[0];
  for (size_t i = 0; i < pl->len; i++) {
    voxgig_value* cand = pl->items[i];
    bool cand_term = terminal_param(cand);
    bool best_term = terminal_param(best);
    if (cand_term != best_term) {
      if (cand_term) best = cand;
    }
    else if (parts_len(cand) < parts_len(best)) {
      best = cand;
    }
  }
  return best;
}

// The path parameters of a point that neither the call nor the entity gives a
// value for, looked up as prepare_params_util looks them up: a list of names.
static voxgig_value* unfilled(Context* ctx, voxgig_value* point) {
  voxgig_value* missing = voxgig_new_list();
  voxgig_value* parts = getp(point, "parts");
  if (!voxgig_is_list(parts)) return missing;

  voxgig_list* pl = voxgig_as_list(parts);
  for (size_t i = 0; i < pl->len; i++) {
    if (!voxgig_is_string(pl->items[i])) continue;
    const char* part = voxgig_as_string(pl->items[i]);
    size_t n = strlen(part);
    if (n < 3 || '{' != part[0] || '}' != part[n - 1] || n - 2 != strcspn(part + 1, "{}/")) continue;

    char* name = (char*)malloc(n - 1);
    memcpy(name, part + 1, n - 2);
    name[n - 2] = '\0';
    voxgig_value* val = param_value(ctx, point, name);
    if (v_is_noval(val) || v_is_null(val)) {
      voxgig_list_push(voxgig_as_list(missing), voxgig_new_string(name));
    }
    free(name);
  }
  return missing;
}

// The names in a list, joined with a comma, malloc'd.
static char* join_names(voxgig_value* names) {
  voxgig_list* nl = voxgig_as_list(names);
  size_t len = 1;
  for (size_t i = 0; i < nl->len; i++) len += strlen(voxgig_as_string(nl->items[i])) + 2;
  char* out = (char*)malloc(len);
  out[0] = '\0';
  for (size_t i = 0; i < nl->len; i++) {
    if (0 < i) strcat(out, ", ");
    strcat(out, voxgig_as_string(nl->items[i]));
  }
  return out;
}

voxgig_value* make_point_util(Context* ctx, PNError** err) {
  *err = NULL;

  // PrePoint short-circuit.
  if (ctx->out_point_kind == OUT_ERR) {
    *err = ctx->out_point_err;
    return NULL;
  }
  if (ctx->out_point_kind == OUT_VAL && voxgig_is_map(ctx->out_point_val)) {
    ctx->point = ctx->out_point_val;
    return ctx->out_point_val;
  }

  Operation* op = ctx->op;
  voxgig_value* options = ctx->options;

  voxgig_value* allow_op_v = getpath2(options, "allow", "op");
  const char* allow_op = voxgig_is_string(allow_op_v) ? voxgig_as_string(allow_op_v) : "";
  if (!allow_list_has(allow_op_v, op->name)) {
    char buf[512];
    snprintf(buf, sizeof(buf),
             "Operation \"%s\" not allowed by SDK option allow.op value: \"%s\"",
             op->name, allow_op);
    *err = context_make_error(ctx, "point_op_allow", buf);
    return NULL;
  }

  voxgig_value* points = op->points;
  int64_t plen = voxgig_size(points);

  if (plen == 0) {
    char buf[256];
    snprintf(buf, sizeof(buf), "Operation \"%s\" has no endpoint definitions.", op->name);
    *err = context_make_error(ctx, "point_no_points", buf);
    return NULL;
  }

  if (plen == 1) {
    ctx->point = get_elem_i(points, 0);
  } else {
    bool is_data = strcmp(op->input, "data") == 0;
    voxgig_value* reqselector = is_data ? ctx->reqdata : ctx->reqmatch;
    voxgig_value* selector = is_data ? ctx->data : ctx->mtch;

    voxgig_value* point = voxgig_new_undef();
    bool matched = false;
    for (int64_t i = 0; i < plen; i++) {
      voxgig_value* cand = get_elem_i(points, i);
      voxgig_value* select_def = to_map(getp(cand, "select"));
      bool found = true;

      if (!v_is_noval(selector) && !v_is_noval(select_def)) {
        voxgig_value* exist = getp(select_def, "exist");
        if (voxgig_is_list(exist)) {
          voxgig_list* el = voxgig_as_list(exist);
          for (size_t j = 0; j < el->len; j++) {
            voxgig_value* ek = el->items[j];
            if (voxgig_is_string(ek)) {
              const char* existkey = voxgig_as_string(ek);
              voxgig_value* rv = getp(reqselector, existkey);
              voxgig_value* sv = getp(selector, existkey);
              if (v_is_noval(rv) && v_is_noval(sv)) { found = false; break; }
            }
          }
        }
      }

      if (found) {
        voxgig_value* req_action = getp(reqselector, "$action");
        voxgig_value* select_action = getp(select_def, "$action");
        if (!v_eq(req_action, select_action)) found = false;
      }

      if (found) {
        point = cand;
        matched = true;
        break;
      }
    }

    // select.exist can list more than the params needed to pick a point, so
    // nothing matches — fall back to the entity's own route rather than
    // whichever point came last.
    if (!matched) {
      // A request naming an action reaches here only because that action's
      // own point failed its exist test, so it is unbuildable whatever we
      // pick. Refuse it BEFORE choosing a fallback: the guard below compares
      // the chosen point's $action and would wave the request through
      // whenever the fallback lands on the action point itself.
      voxgig_value* unmatched_action = getp(reqselector, "$action");
      if (!v_is_noval(unmatched_action)) {
        char* actstr = voxgig_stringify(unmatched_action, -1);
        char buf[512];
        snprintf(buf, sizeof(buf), "Operation \"%s\" action \"%s\" is not valid.",
                 op->name, actstr ? actstr : "");
        *err = context_make_error(ctx, "point_action_invalid", buf);
        return NULL;
      }

      // A call without an action falls back to a point without one, as
      // generation does, and only to a route the call can fill.
      voxgig_value* plain = voxgig_new_list();
      for (int64_t i = 0; i < plen; i++) {
        voxgig_value* cand = get_elem_i(points, i);
        if (v_is_noval(getp(to_map(getp(cand, "select")), "$action"))) {
          voxgig_list_push(voxgig_as_list(plain), v_share(cand));
        }
      }
      if (0 == voxgig_as_list(plain)->len) {
        voxgig_release(plain);
        char buf[512];
        snprintf(buf, sizeof(buf),
                 "Operation \"%s\" has only action endpoints; pass $action to choose one.",
                 op->name);
        *err = context_make_error(ctx, "point_action_required", buf);
        return NULL;
      }
      voxgig_value* fillable = voxgig_new_list();
      voxgig_list* plain_l = voxgig_as_list(plain);
      for (size_t i = 0; i < plain_l->len; i++) {
        voxgig_value* missing = unfilled(ctx, plain_l->items[i]);
        if (0 == voxgig_as_list(missing)->len) {
          voxgig_list_push(voxgig_as_list(fillable), v_share(plain_l->items[i]));
        }
        voxgig_release(missing);
      }

      if (0 == voxgig_as_list(fillable)->len) {
        voxgig_value* missing = unfilled(ctx, own_point(plain));
        char* names = join_names(missing);
        char buf[512];
        snprintf(buf, sizeof(buf),
                 "Operation \"%s\" has no endpoint whose path parameters are all given (missing: %s).",
                 op->name, names);
        free(names);
        voxgig_release(missing);
        voxgig_release(fillable);
        voxgig_release(plain);
        *err = context_make_error(ctx, "point_no_match", buf);
        return NULL;
      }

      point = own_point(fillable);
      voxgig_release(fillable);
      voxgig_release(plain);
    }

    voxgig_value* req_action = getp(reqselector, "$action");
    if (!v_is_noval(req_action) && !v_is_noval(point)) {
      voxgig_value* point_select = to_map(getp(point, "select"));
      voxgig_value* point_action = getp(point_select, "$action");
      if (!v_eq(req_action, point_action)) {
        char* actstr = voxgig_stringify(req_action, -1);
        char buf[512];
        snprintf(buf, sizeof(buf), "Operation \"%s\" action \"%s\" is not valid.",
                 op->name, actstr ? actstr : "");
        *err = context_make_error(ctx, "point_action_invalid", buf);
        return NULL;
      }
    }

    ctx->point = point;
  }

  return ctx->point;
}
