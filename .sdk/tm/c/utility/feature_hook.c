// feature_hook utility (mirrors utility/feature_hook.rs). Snapshot the list
// so a hook that mutates the feature set does not invalidate iteration.

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

void feature_hook_util(Context* ctx, const char* name) {
  UnivecSDK* client = ctx->client;
  if (!client) return;

  size_t n = client->features_len;
  if (n == 0) return;
  Feature** snapshot = (Feature**)malloc(n * sizeof(Feature*));
  memcpy(snapshot, client->features, n * sizeof(Feature*));

  for (size_t i = 0; i < n; i++) {
    snapshot[i]->vt->hook(snapshot[i], name, ctx);
  }
  free(snapshot);
}
