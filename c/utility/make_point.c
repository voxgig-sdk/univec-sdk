// make_point utility (mirrors utility/make_point.rs). Honours a PrePoint
// short-circuit (rbac stores an error in ctx.out point).

#include "sdk.h"

#include <stdio.h>
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
  if (!strstr(allow_op, op->name)) {
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

      point = get_elem_i(points, 0);
      for (int64_t i = 0; i < plen; i++) {
        voxgig_value* cand = get_elem_i(points, i);
        bool cand_term = terminal_param(cand);
        bool best_term = terminal_param(point);
        if (cand_term != best_term) {
          if (cand_term) point = cand;
        }
        else if (parts_len(cand) < parts_len(point)) {
          point = cand;
        }
      }
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
