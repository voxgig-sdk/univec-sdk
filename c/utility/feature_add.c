// feature_add utility (mirrors utility/feature_add.rs). A feature whose
// add_options() names an already-added feature via __before__/__after__/
// __replace__ positions itself relative to it; else it is appended.

#include "sdk.h"

#include <string.h>

void feature_add_util(Context* ctx, Feature* f) {
  UnivecSDK* client = ctx->client;
  if (!client) return;

  voxgig_value* fopts = f->vt->add_options(f);
  if (fopts && voxgig_is_map(fopts)) {
    const char* before = get_str(fopts, "__before__");
    const char* after = get_str(fopts, "__after__");
    const char* replace = get_str(fopts, "__replace__");
    before = before ? before : "";
    after = after ? after : "";
    replace = replace ? replace : "";

    if (before[0] || after[0] || replace[0]) {
      for (size_t i = 0; i < client->features_len; i++) {
        const char* name = client->features[i]->vt->name(client->features[i]);
        if (before[0] && strcmp(before, name) == 0) {
          sdk_features_insert(client, i, f);
          return;
        }
        if (after[0] && strcmp(after, name) == 0) {
          sdk_features_insert(client, i + 1, f);
          return;
        }
        if (replace[0] && strcmp(replace, name) == 0) {
          sdk_features_replace(client, i, f);
          return;
        }
      }
    }
  }

  sdk_features_push(client, f);
}
