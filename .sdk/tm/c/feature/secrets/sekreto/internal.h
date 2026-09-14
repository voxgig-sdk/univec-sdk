// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/src/internal.h)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* What the CORE's own files share, and a consumer never sees: the string
 * helpers and the one local-file read the four built-in kinds need.
 *
 * THE PLUGINS SEE IT TOO, and that direction is the whole point. A plugin
 * compiles against this header and links against the core archive; the
 * core names nothing under `plugins/`, so a build of the core cannot pull
 * one in. Everything a plugin needs that the core must not link - the
 * HTTP transport, TLS, the SHA-256 primitives, a child process - is in
 * `plugins/support.h` instead.
 *
 * Nothing declared here opens a socket, spawns a child or hashes
 * anything. `make check-core` reads the core archive's own list of
 * undefined symbols and says so.
 */

#ifndef VOXGIG_SEKRETO_INTERNAL_H
#define VOXGIG_SEKRETO_INTERNAL_H

#include <stddef.h>

#include "sekreto.h"

/* ---- string helpers ------------------------------------------------ */

int sek_empty(const char *text);
const char *sek_first(const char *a, const char *b);
/* The first candidate that is set and non-empty, or "". */
const char *sek_first3(const char *a, const char *b, const char *c);
const char *sek_orempty(const char *text);
int sek_has_prefix(const char *text, const char *prefix);
int sek_contains(const char *hay, const char *needle);
char *sek_trimslash(sek_pool *pool, const char *text);
char *sek_bareurl(sek_pool *pool, const char *url);
char sek_upper(char ch);
char sek_lower(char ch);
char *sek_lowercase(sek_pool *pool, const char *text);

/* ---- reading a local file ------------------------------------------ */

/* The whole file, or NULL with `*why` set to errno.
 *
 * This is the FLOOR of what a built-in kind may do - `dotenv` reads a
 * `.env`, `file` reads a mounted secret directory - and it is the reason
 * the line between core and plugin is "reads at most a local file"
 * rather than "imports nothing". */
char *sek_readfile(sek_pool *pool, const char *path, int *why);

/* Does this read failure mean "no secrets here", rather than "I could not
 * answer"?
 *
 * Absence is a MISS and the chain carries on; anything else - permission
 * denied, an unreadable mount, a failing disk - is an ERROR, because
 * returning a miss there falls silently through to a weaker store.
 *
 * ENOENT and ENOTDIR are the two absence codes: a missing file, a missing
 * directory, and a path whose parent is a plain file. EACCES is NOT one
 * of them, which is the case the rule exists for - the obvious spelling,
 * an `exists()` predicate, answers false for a locked mount and would
 * turn it into a miss. */
int sek_absent(int why);

/* ---- the construction slot ----------------------------------------- */

/* HOW A PROVIDER CROSSES THE PLUGIN BOUNDARY.
 *
 * voxgig/plugin's value model carries numbers and strings, never
 * pointers, and its Definition carries no context. So for the duration of
 * one sek_new the pool travels to each kind's `define` through a
 * file-scope slot, and each `define` exports the INDEX of the provider it
 * built; sek_new reads the index back and looks the pointer up here. It
 * is the shape the zig port arrived at, and the shape plugin's own C port
 * uses for its pending error.
 *
 * This is why sek_new is not reentrant, and it says so. */
/* A spec as the options map its plugin instance is declared with: the
 * spec's own key names, the shape a config document would have. */
Value *sek_optionsof(const sek_spec *spec);

void sek_build_begin(sek_pool *pool);
void sek_build_end(void);
sek_provider *sek_build_at(double index);

#endif /* VOXGIG_SEKRETO_INTERNAL_H */
