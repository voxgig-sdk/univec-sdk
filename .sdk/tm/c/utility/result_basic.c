// result_basic utility (mirrors utility/result_basic.rs).

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char* dup_str(const char* s) {
  if (!s) s = "";
  size_t n = strlen(s);
  char* d = (char*)malloc(n + 1);
  memcpy(d, s, n + 1);
  return d;
}

SdkResult* result_basic_util(Context* ctx) {
  Response* response = ctx->response;
  SdkResult* result = ctx->result;

  if (result && response) {
    result->status = response->status;
    free(result->status_text);
    result->status_text = dup_str(response->status_text);

    if (result->status >= 400) {
      char msg[512];
      snprintf(msg, sizeof(msg), "request: %lld: %s",
               (long long)result->status, result->status_text);
      if (result->err) {
        char buf[1024];
        snprintf(buf, sizeof(buf), "%s: %s", result->err->msg, msg);
        result->err = context_make_error(ctx, "request_status", buf);
      } else {
        result->err = context_make_error(ctx, "request_status", msg);
      }
    } else if (response->err) {
      result->err = response->err;
    }
  }

  return result;
}
