// make_result utility (mirrors utility/make_result.rs).

#include "sdk.h"

#include <string.h>

SdkResult* make_result_util(Context* ctx, PNError** err) {
  *err = NULL;

  if (ctx->out_result) {
    return ctx->out_result;
  }

  Operation* op = ctx->op;
  Entity* entity = ctx->entity;
  Spec* spec = ctx->spec;
  if (!spec) {
    *err = context_make_error(ctx, "result_no_spec", "Expected context spec property to be defined.");
    return NULL;
  }
  SdkResult* result = ctx->result;
  if (!result) {
    *err = context_make_error(ctx, "result_no_result", "Expected context result property to be defined.");
    return NULL;
  }

  spec_set_step(spec, "result");

  transform_response_util(ctx);

  if (strcmp(op->name, "list") == 0) {
    voxgig_value* resdata = result->resdata;
    result->resdata = voxgig_new_list();

    if (voxgig_is_list(resdata) && entity) {
      voxgig_list* list = voxgig_as_list(resdata);
      if (list->len > 0) {
        voxgig_value* entities = voxgig_new_list();
        for (size_t i = 0; i < list->len; i++) {
          voxgig_value* entry = list->items[i];
          Entity* e = entity->vt->make(entity);
          voxgig_value* out;
          if (voxgig_is_map(entry)) {
            out = e->vt->data(e, entry);
          } else {
            out = e->vt->data(e, NULL);
          }
          voxgig_list_push(voxgig_as_list(entities), voxgig_retain(out));
        }
        result->resdata = entities;
      }
    }
  }

  Control* c = ctx->ctrl;
  if (control_has_explain(c)) {
    setp(c->explain, "result", result_to_value(result));
  }

  return result;
}
