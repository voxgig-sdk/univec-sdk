// The Utility bundle (mirrors core/utility_type.rs) + the SDK client-base
// generic helpers. Go carries utilities as swappable function pointers; C
// keeps the two members that genuinely vary swappable: the transport
// (`fetcher`, wrapped by features) and the `custom` map of caller utilities.

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

Utility* utility_new(void) {
  Utility* u = (Utility*)calloc(1, sizeof(Utility));
  u->fetcher = (Fetcher*)calloc(1, sizeof(Fetcher));
  u->fetcher->fn = fetcher_util;
  u->fetcher->state = NULL;
  u->custom = voxgig_new_map();
  return u;
}

Utility* utility_copy(Utility* src) {
  Utility* u = (Utility*)calloc(1, sizeof(Utility));
  // Share the (possibly feature-wrapped) fetcher.
  u->fetcher = src->fetcher;
  // Shallow copy of the custom map.
  voxgig_value* custom = voxgig_new_map();
  if (voxgig_is_map(src->custom)) {
    voxgig_map* m = voxgig_as_map(src->custom);
    for (size_t i = 0; i < m->len; i++) {
      setp(custom, m->entries[i].key, voxgig_retain(m->entries[i].value));
    }
  }
  u->custom = custom;
  return u;
}

voxgig_value* utility_fetch(Utility* u, Context* ctx, const char* url,
                            voxgig_value* fetchdef, PNError** err) {
  return u->fetcher->fn(u->fetcher, ctx, url, fetchdef, err);
}

// ---- SDK client-base generic helpers (Main.fragment UnivecSDK) -------

void sdk_features_push(UnivecSDK* sdk, Feature* f) {
  if (sdk->features_len + 1 > sdk->features_cap) {
    size_t nc = sdk->features_cap == 0 ? 8 : sdk->features_cap * 2;
    sdk->features = (Feature**)realloc(sdk->features, nc * sizeof(Feature*));
    sdk->features_cap = nc;
  }
  sdk->features[sdk->features_len++] = f;
}

void sdk_features_insert(UnivecSDK* sdk, size_t i, Feature* f) {
  if (i >= sdk->features_len) { sdk_features_push(sdk, f); return; }
  if (sdk->features_len + 1 > sdk->features_cap) {
    size_t nc = sdk->features_cap == 0 ? 8 : sdk->features_cap * 2;
    sdk->features = (Feature**)realloc(sdk->features, nc * sizeof(Feature*));
    sdk->features_cap = nc;
  }
  for (size_t j = sdk->features_len; j > i; j--) {
    sdk->features[j] = sdk->features[j - 1];
  }
  sdk->features[i] = f;
  sdk->features_len++;
}

void sdk_features_replace(UnivecSDK* sdk, size_t i, Feature* f) {
  if (i < sdk->features_len) sdk->features[i] = f;
}

voxgig_value* sdk_options_map(UnivecSDK* sdk) { return voxgig_clone(sdk->options); }

Utility* sdk_get_utility(UnivecSDK* sdk) { return utility_copy(sdk->utility); }

Context* sdk_get_root_ctx(UnivecSDK* sdk) { return sdk->rootctx; }
