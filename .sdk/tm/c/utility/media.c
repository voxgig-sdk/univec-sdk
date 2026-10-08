// The media types a point declares (mirrors utility/media.rs): `response`
// (the model's `rs`) for the Accept header, and `body` (the model's `rb`)
// for the request body.

#include "sdk.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

static bool ieq_n(const char* s, size_t n, const char* lit) {
  if (strlen(lit) != n) return false;
  for (size_t i = 0; i < n; i++) {
    if (tolower((unsigned char)s[i]) != lit[i]) return false;
  }
  return true;
}

bool media_is_json(const char* media) {
  if (NULL == media) return false;
  size_t n = strcspn(media, ";");
  while (n > 0 && isspace((unsigned char)media[n - 1])) n--;
  while (n > 0 && isspace((unsigned char)*media)) {
    media++;
    n--;
  }
  return ieq_n(media, n, "application/json") || ieq_n(media, n, "text/json") ||
         (n >= 5 && ieq_n(media + n - 5, 5, "+json"));
}

// The declared JSON type alone, else every declared type in the model's
// order; NULL when no success response declares a body. Malloc'd.
char* media_accept_of(voxgig_value* point) {
  voxgig_value* res = getp(point, "response");
  const char* media = get_str(res, "media");
  if (NULL == media || '\0' == *media) return NULL;
  bool json = v_str_eq(getp(res, "kind"), "json");

  voxgig_value* alts = getp(res, "alternatives");
  voxgig_list* al = !json && v_is_list(alts) ? voxgig_as_list(alts) : NULL;
  size_t cap = strlen(media) + 1;
  for (size_t i = 0; NULL != al && i < al->len; i++) {
    const char* m = get_str(al->items[i], "media");
    if (NULL != m && '\0' != *m) cap += strlen(m) + 2;
  }
  char* out = (char*)malloc(cap);
  strcpy(out, media);
  for (size_t i = 0; NULL != al && i < al->len; i++) {
    const char* m = get_str(al->items[i], "media");
    if (NULL != m && '\0' != *m) {
      strcat(out, ", ");
      strcat(out, m);
    }
  }
  return out;
}

bool media_is_raw_request(voxgig_value* point) {
  return v_str_eq(getp(getp(point, "body"), "kind"), "raw");
}

bool media_is_json_request(voxgig_value* point) {
  return v_str_eq(getp(getp(point, "body"), "kind"), "json");
}

static bool has_header(voxgig_value* headers, const char* name) {
  voxgig_map* hm = voxgig_as_map(headers);
  for (size_t j = 0; j < hm->len; j++) {
    if (ieq_n(hm->entries[j].key, strlen(hm->entries[j].key), name)) return true;
  }
  return false;
}

// A caller's accept wins. A declared request type replaces each JSON
// content-type, the SDK default, and leaves any other the caller set.
void media_headers(voxgig_value* point, voxgig_value* headers) {
  if (!v_is_map(headers)) return;

  char* accept = media_accept_of(point);
  if (NULL != accept) {
    if (!has_header(headers, "accept")) setp(headers, "accept", v_str(accept));
    free(accept);
  }

  voxgig_value* body = getp(point, "body");
  const char* media = get_str(body, "media");
  if ((v_str_eq(getp(body, "kind"), "raw") || v_str_eq(getp(body, "kind"), "json")) &&
      NULL != media && '\0' != *media) {
    voxgig_map* hm = voxgig_as_map(headers);
    for (size_t j = hm->len; j > 0; j--) {
      const char* key = hm->entries[j - 1].key;
      voxgig_value* val = hm->entries[j - 1].value;
      if (ieq_n(key, strlen(key), "content-type") && voxgig_is_string(val) &&
          media_is_json(voxgig_as_string(val))) {
        voxgig_value* dk = voxgig_new_string(key);
        voxgig_delprop(headers, dk);
        voxgig_release(dk);
      }
    }
    if (!has_header(headers, "content-type")) setp(headers, "content-type", v_str(media));
  }
}

// A string value of text or bytes: its length, not a NUL, ends it.
voxgig_value* media_raw_body(voxgig_value* reqdata) {
  return getp(reqdata, "$body");
}
