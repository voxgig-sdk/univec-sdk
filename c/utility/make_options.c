// make_options utility (mirrors utility/make_options.rs).

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int mo_cmp_cstr(const void* a, const void* b) {
  return strcmp(*(const char* const*)a, *(const char* const*)b);
}

static voxgig_value* mo_plain(voxgig_value* val, const char* name) {
  if (!voxgig_is_map(val)) return voxgig_retain(val);
  voxgig_value* out = v_map();
  voxgig_map* m = voxgig_as_map(val);
  int rbac = NULL != name && 0 == strcmp(name, "rbac");
  for (size_t i = 0; i < m->len; i++) {
    const char* k = m->entries[i].key;
    if (0 != strcmp(k, "entity") && !(rbac && 0 == strcmp(k, "rules"))) {
      setp(out, k, voxgig_retain(m->entries[i].value));
    }
  }
  return out;
}

// The options to scan for secrets. The feature map is keyed by feature
// names, not field names, so it is scanned as a list: `secrets` must not
// make every setting of that feature a secret. Entity blocks hold entity
// settings and seeded records, never a credential, so none is scanned, and
// nor are rbac's rules, keyed by entity and operation names.
static voxgig_value* mo_without(voxgig_value* val, const char* k1, const char* k2) {
  voxgig_value* out = v_map();
  if (!voxgig_is_map(val)) return out;
  voxgig_map* m = voxgig_as_map(val);
  for (size_t i = 0; i < m->len; i++) {
    const char* k = m->entries[i].key;
    voxgig_value* v = m->entries[i].value;
    if (0 == strcmp(k, "entity")) continue;
    if ((k1 && 0 == strcmp(k, k1)) || (k2 && 0 == strcmp(k, k2))) continue;
    if (0 == strcmp(k, "feature") && voxgig_is_map(v)) {
      voxgig_value* list = v_list();
      voxgig_map* fm = voxgig_as_map(v);
      for (size_t f = 0; f < fm->len; f++) {
        voxgig_list_push(voxgig_as_list(list), mo_plain(fm->entries[f].value, fm->entries[f].key));
      }
      v = list;
    } else if (0 == strcmp(k, "test")) {
      v = mo_plain(v, NULL);
    } else {
      voxgig_retain(v);
    }
    setp(out, k, v);
  }
  return out;
}

// A copy of the clean block, or an empty one: merge lets a missing value
// replace everything merged before it, schema defaults included.
static voxgig_value* mo_clean_block(voxgig_value* opts) {
  voxgig_value* block = getp(opts, "clean");
  return voxgig_is_map(block) ? voxgig_clone(block) : v_map();
}

static bool mo_true(voxgig_value* v) {
  return voxgig_is_bool(v) && voxgig_as_bool(v);
}

static bool mo_namechar(char c) {
  return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9') || '_' == c;
}

static void mo_append(char** out, size_t* len, size_t* cap, const char* s, size_t n) {
  while (*len + n + 1 > *cap) {
    *cap *= 2;
    *out = (char*)realloc(*out, *cap);
  }
  memcpy(*out + *len, s, n);
  *len += n;
  (*out)[*len] = '\0';
}

/* A templated base URL takes each {name} from options.server. An empty value
 * cannot make a working URL, so construction stops, as a rust or zig panic
 * does, except in test mode, where it becomes test-<name>. */
static void mo_resolve_base(voxgig_value* opts, voxgig_value* config) {
  const char* base = get_str(opts, "base");
  if (NULL == base || NULL == strchr(base, '{')) return;

  bool testmode = mo_true(getpath2(opts, "test", "active"))
    || mo_true(getpath3(opts, "feature", "test", "active"));
  voxgig_value* server = to_map(getp(opts, "server"));
  const char* sdkname = get_str(getp(config, "main"), "name");
  if (NULL == sdkname || '\0' == sdkname[0]) sdkname = "SDK";

  size_t blen = strlen(base);
  size_t len = 0;
  size_t cap = blen + 1;
  char* out = (char*)malloc(cap);
  out[0] = '\0';
  size_t i = 0;
  while (i < blen) {
    size_t j = i + 1;
    if ('{' == base[i]) {
      while (j < blen && mo_namechar(base[j])) j++;
    }
    // A placeholder only when it closes and the name is [A-Za-z0-9_]+.
    if ('{' != base[i] || j == i + 1 || j >= blen || '}' != base[j]) {
      mo_append(&out, &len, &cap, base + i, 1);
      i++;
      continue;
    }
    size_t nlen = j - i - 1;
    char* name = (char*)malloc(nlen + 1);
    memcpy(name, base + i + 1, nlen);
    name[nlen] = '\0';
    const char* val = get_str(server, name);
    if (NULL != val && '\0' != val[0]) {
      mo_append(&out, &len, &cap, val, strlen(val));
    } else if (testmode) {
      mo_append(&out, &len, &cap, "test-", 5);
      mo_append(&out, &len, &cap, name, nlen);
    } else {
      fprintf(stderr, "%s: the server variable '%s' is required: the API base URL is '%s'"
              " - pass cmap(1, \"server\", cmap(1, \"%s\", v_str(\"...\"))) in the SDK options\n",
              sdkname, name, base, name);
      fflush(stderr);
      abort();
    }
    free(name);
    i = j + 1;
  }
  setp(opts, "base", v_str(out));
  free(out);
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

  /* `auth: null` is the documented way to disable auth outright, and
   * prepare_auth honours it before it ever reads the apikey. validate would
   * erase it: this port follows the Group A rule, so a stored null reads as
   * "no value" and the optspec's `auth` default fires instead - transmitting
   * the credential the caller withheld. Put the null back afterwards.
   *
   * Unlike js, no delete-before-validate is needed here: Group A means
   * validate DEFAULTS rather than rejecting, so the key can travel through.
   *
   * Read the map DIRECTLY rather than through getp, which applies that same
   * rule and so cannot tell an absent auth from a suppressed one. */
  bool auth_suppressed = false;
  if (voxgig_is_map(options)) {
    voxgig_value* authval = voxgig_map_get(voxgig_as_map(options), "auth");
    auth_suppressed = (NULL != authval && voxgig_is_null(authval));
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

  /* THE OPTION SPEC IS GENERATED, NOT WRITTEN HERE.
   *
   * Built from the model: `main.kit.optspec` for the standard options, plus
   * one entry per feature this target carries, from that feature's own
   * `config.options` / `config.optspec`. Editing this file to add an option
   * would put it back where it was - one of twenty hand-maintained copies of
   * a schema nothing cross-checked - so add it to the model instead and every
   * ported target validates it.
   *
   * Parsed once and shared: make_options validates AGAINST the spec and
   * writes into the options, never into the spec. */
  voxgig_value* optspec = shared_optspec();

  /* The secret registry exists BEFORE validation, fed from the raw input.
   * Its block is shared by pointer: what is registered into `cleanopts`
   * here is what `opts.__derived__.clean` carries out below. */
  voxgig_value* cleancfg = clean_make_config(voxgig_merge(
    clist(4, v_map(), voxgig_clone(getp(optspec, "clean")),
          mo_clean_block(cfgopts), mo_clean_block(opts)),
    VOXGIG_MAXDEPTH));
  voxgig_value* cleanopts = cmap(1, "__derived__", cmap(1, "clean", v_share(cleancfg)));
  clean_add_sensitive_opts(cleanopts, mo_without(opts, "clean", NULL));
  voxgig_value* valueblocks[2] = { cfgopts, opts };
  for (int b = 0; b < 2; b++) {
    voxgig_list* rawvals =
      voxgig_as_list(clean_split_values(getpath2(valueblocks[b], "clean", "values")));
    for (size_t i = 0; i < rawvals->len; i++) {
      clean_add_opts(cleanopts, voxgig_as_string(rawvals->items[i]));
    }
  }

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

  /* Restore the suppression the optspec default would otherwise erase. */
  if (auth_suppressed) {
    setp(opts, "auth", voxgig_new_null());
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

  mo_resolve_base(opts, config);

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
       cmap(2, "clean", v_share(cleancfg), "featureorder", feature_order));

  // Again over the merged result: the config's own defaults can carry one.
  clean_add_sensitive_opts(opts, mo_without(opts, "clean", "__derived__"));

  return opts;
}
