// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/clock.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The clock the vault clients share: when a leased token must be renewed,
 * and the timestamp SigV4 signs.
 *
 * Its own translation unit because `sek_nowms` is the transport's
 * deadline clock as well, and the transport must not drag a child-process
 * launcher into a link that has no CLI store in it.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "support.h"

/* MONOTONIC, not wall time: every deadline in this library is a duration
 * from now, and a clock the operator can step backwards would turn a
 * ten-second timeout into a hang. */
long long sek_nowms(void) {
  struct timespec now;

  clock_gettime(CLOCK_MONOTONIC, &now);

  return (long long)now.tv_sec * 1000ll + now.tv_nsec / 1000000ll;
}

/* now + max(seconds - 60, 1), so a token is renewed shortly before its
 * lease runs out rather than after a vault has already expired it. A
 * missing or zero expiry means never renew, which is what a configured
 * token gets. */
long long sek_renewtime(const sek_json *expires) {
  double seconds = 0;

  if (NULL == expires) {
    return SEK_NEVER;
  }

  if (SEK_JSON_NUM == expires->type) {
    seconds = expires->numval;
  } else if (SEK_JSON_STR == expires->type) {
    /* Azure IMDS sends expires_in as a STRING. */
    char *stop = NULL;
    seconds = strtod(expires->strval, &stop);
    if (NULL == stop || stop == expires->strval) {
      seconds = 0;
    }
  }

  if (!(0 < seconds)) {
    return SEK_NEVER;
  }

  if (60 < seconds) {
    seconds -= 60;
  } else {
    seconds = 1;
  }

  return sek_nowms() + (long long)(seconds * 1000);
}

char *sek_awsnow(sek_pool *pool) {
  time_t now = time(NULL);
  struct tm parts;
  char buf[32];

  gmtime_r(&now, &parts);
  strftime(buf, sizeof(buf), "%Y%m%dT%H%M%SZ", &parts);

  return sek_strdup(pool, buf);
}
