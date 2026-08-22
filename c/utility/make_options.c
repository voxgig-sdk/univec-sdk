// make_options utility (mirrors utility/make_options.rs).

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

static int mo_cmp_cstr(const void* a, const void* b) {
  return strcmp(*(const char* const*)a, *(const char* const*)b);
}

voxgig_value* make_options_util(Context* ctx) {
  voxgig_value* options = voxgig_is_map(ctx->options) ? ctx->options : voxgig_new_map();

  // Merge custom utility overrides onto the utility object.
  voxgig_value* custom_utils = to_map(getp(options, "utility"));
  if (voxgig_is_map(custom_utils) && ctx->utility) {
    voxgig_value* custom = ctx->utility->custom;
    voxgig_map* cm = voxgig_as_map(custom_utils);
    for (size_t i = 0; i < cm->len; i++) {
      setp(custom, cm->entries[i].key, voxgig_retain(cm->entries[i].value));
    }
  }

  voxgig_value* opts = voxgig_clone(options);

  // Feature add-order. options.feature may be an ordered list of
  // { name, active, ...opts } entries (the list position IS the order in which
  // features are added), or a { name: {opts} } map. Normalize a list to a map
  // (so merge/validate are unchanged) and remember the explicit order; a map
  // defaults to test-first so the `test` mock transport is installed as the
  // base of the transport wrapper chain.
  voxgig_value* feature_order = v_list();
  voxgig_value* raw_feature = getp(opts, "feature");
  if (v_is_list(raw_feature)) {
    voxgig_value* fmap = v_map();
    voxgig_list* fl = voxgig_as_list(raw_feature);
    for (size_t i = 0; i < fl->len; i++) {
      voxgig_value* entry = fl->items[i];
      if (v_is_map(entry)) {
        const char* nm = get_str(entry, "name");
        if (nm) {
          voxgig_value* fopts = v_clone(entry);
          voxgig_delprop(fopts, v_str("name"));
          setp(fmap, nm, fopts);
          voxgig_list_push(voxgig_as_list(feature_order), v_str(nm));
        }
      }
    }
    setp(opts, "feature", fmap);
  }

  voxgig_value* config = ctx->config;
  voxgig_value* cfgopts = to_map(getp(config, "options"));
  if (!voxgig_is_map(cfgopts)) cfgopts = voxgig_new_map();

  // Build the option spec (validation shape). Marker keys use backticks.
  voxgig_value* optspec = cmap(13,
    "apikey", v_str(""),
    "base", v_str("http://localhost:8000"),
    "prefix", v_str(""),
    "suffix", v_str(""),
    "auth", cmap(1, "prefix", v_str("")),
    "headers", cmap(1, "`$CHILD`", v_str("`$STRING`")),
    "allow", cmap(2,
      "method", v_str("GET,PUT,POST,PATCH,DELETE,OPTIONS"),
      "op", v_str("create,update,load,list,remove,command,direct,graphql")),
    "entity", cmap(1, "`$CHILD`", cmap(3,
      "`$OPEN`", v_bool(true),
      "active", v_bool(false),
      "alias", v_map())),
    "feature", cmap(1, "`$CHILD`", cmap(2,
      "`$OPEN`", v_bool(true),
      "active", v_bool(false))),
    "utility", v_map(),
    "system", v_map(),
    "test", cmap(2,
      "active", v_bool(false),
      "entity", cmap(1, "`$OPEN`", v_bool(true))),
    "clean", cmap(1, "keys", v_str("key,token,id")));

  // Preserve system.fetch before merge/validate (validation strips it).
  voxgig_value* sys_fetch = getpath2(opts, "system", "fetch");

  /* CLONE the config side, do not v_share it: `config` is a process-wide
   * singleton (shared_config) and merge uses its nested maps as merge TARGETS,
   * so sharing lets one client's options (headers, server, ...) be written into
   * the shared config and inherited by every client built afterwards. */
  voxgig_value* mergelist = clist(3, v_map(), voxgig_clone(cfgopts), v_share(opts));
  voxgig_value* merged = voxgig_merge(mergelist, VOXGIG_MAXDEPTH);
  voxgig_value* validated = voxgig_validate(merged, optspec, NULL);
  if (voxgig_is_map(validated)) {
    opts = validated;
  }

  // Restore system.fetch.
  if (!v_is_noval(sys_fetch)) {
    voxgig_value* sys = getp(opts, "system");
    if (voxgig_is_map(sys)) {
      setp(sys, "fetch", v_share(sys_fetch));
    } else {
      setp(opts, "system", cmap(1, "fetch", v_share(sys_fetch)));
    }
  }

  // Derived clean config.
  voxgig_value* clean_keys_v = getpath2(opts, "clean", "keys");
  const char* clean_keys = voxgig_is_string(clean_keys_v) ? voxgig_as_string(clean_keys_v)
                                                          : "key,token,id";

  // Split on ',', trim, filter empty, esc_re each, join with '|'.
  char* keyre = (char*)malloc(1);
  keyre[0] = '\0';
  size_t keyre_len = 0;
  bool first = true;
  const char* p = clean_keys;
  while (1) {
    const char* comma = strchr(p, ',');
    size_t seglen = comma ? (size_t)(comma - p) : strlen(p);
    // trim
    const char* start = p;
    const char* end = p + seglen;
    while (start < end && (*start == ' ' || *start == '\t')) start++;
    while (end > start && (end[-1] == ' ' || end[-1] == '\t')) end--;
    if (end > start) {
      char* seg = (char*)malloc((size_t)(end - start) + 1);
      memcpy(seg, start, (size_t)(end - start));
      seg[end - start] = '\0';
      char* esc = voxgig_escre(v_str(seg));
      free(seg);
      const char* e = esc ? esc : "";
      size_t elen = strlen(e);
      size_t extra = elen + (first ? 0 : 1);
      keyre = (char*)realloc(keyre, keyre_len + extra + 1);
      if (!first) keyre[keyre_len++] = '|';
      memcpy(keyre + keyre_len, e, elen);
      keyre_len += elen;
      keyre[keyre_len] = '\0';
      free(esc);
      first = false;
    }
    if (!comma) break;
    p = comma + 1;
  }

  voxgig_value* derived_clean = (keyre_len == 0) ? v_map()
                                                 : cmap(1, "keyre", v_str(keyre));
  free(keyre);

  // Resolve the feature add-order: an explicit list order (above) wins;
  // otherwise order the map test-first, then the remaining names sorted, so
  // the outcome is deterministic and `test` is always the base transport.
  if (voxgig_as_list(feature_order)->len == 0) {
    voxgig_value* fmap = getp(opts, "feature");
    if (v_is_map(fmap)) {
      voxgig_map* fm = voxgig_as_map(fmap);
      size_t fn = fm->len;
      if (fn > 0) {
        const char** names = (const char**)malloc(sizeof(char*) * fn);
        for (size_t i = 0; i < fn; i++) names[i] = fm->entries[i].key;
        qsort(names, fn, sizeof(char*), mo_cmp_cstr);
        bool has_test = false;
        for (size_t i = 0; i < fn; i++) {
          if (strcmp(names[i], "test") == 0) has_test = true;
        }
        if (has_test) {
          voxgig_list_push(voxgig_as_list(feature_order), v_str("test"));
        }
        // Station special case, mirroring test's: its transport wrap must
        // sit immediately outside the base transport (inside retry/cache/
        // netsim), so map-form activation hoists it to just after test -
        // or first, when no test entry exists. Without this the sorted
        // default would init station last and wrap OUTSIDE the recording
        // features, turning its wire-truth events into fiction.
        for (size_t i = 0; i < fn; i++) {
          if (strcmp(names[i], "station") == 0) {
            voxgig_list_push(voxgig_as_list(feature_order), v_str("station"));
          }
        }
        for (size_t i = 0; i < fn; i++) {
          if (strcmp(names[i], "test") != 0 && strcmp(names[i], "station") != 0) {
            voxgig_list_push(voxgig_as_list(feature_order), v_str(names[i]));
          }
        }
        free(names);
      }
    }
  }

  setp(opts, "__derived__",
       cmap(2, "clean", derived_clean, "featureorder", feature_order));

  return opts;
}
