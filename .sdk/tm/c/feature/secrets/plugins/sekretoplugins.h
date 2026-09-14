// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/sekretoplugins.h)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The ten provider kinds that are NOT built in, each a voxgig/plugin
 * definition, plus the transport and the SigV4 signing that come with
 * them.
 *
 * What makes a kind a plugin is that it needs more of the platform than a
 * local file: a socket, a signature or a child process. A chain of the
 * four built-in kinds links none of this, which is the whole point of the
 * split (docs/design/plugin-providers.md).
 *
 * LINKING IS THE BOUNDARY, AND A HEADER IS NOT LINKING. Declaring all ten
 * here costs a consumer nothing: what a binary carries is the objects its
 * link line names. A lean consumer links `plugins/hashicorp.o` and the
 * transport it needs, hands `sek_plugin_hashicorp()` to sek_options, and
 * never has AWS request signing, seven other vault clients or the child
 * process launcher in its binary. `sek_allplugins` is the opposite trade
 * and the honest one: it names all ten, so an object referencing it pulls
 * every plugin in the library.
 *
 *     Definition *chain[] = {sek_plugin_hashicorp()};
 *     sek_options opts = {0};
 *     opts.plugins = chain;
 *     opts.plugincount = 1;
 */

#ifndef VOXGIG_SEKRETO_PLUGINS_H
#define VOXGIG_SEKRETO_PLUGINS_H

#include <stddef.h>

#include "sekreto.h"

/* ---- the kinds ----------------------------------------------------- */

/* HashiCorp Vault over its HTTP API: KV v1 and v2, a configured token or
 * a login (kubernetes, approle, jwt), and Vault Enterprise namespaces. */
Definition *sek_plugin_hashicorp(void);

/* A boru vault: the `boru` CLI, or the same vault over its wire protocol
 * when an address and a capability token are configured. */
Definition *sek_plugin_boru(void);

/* AWS Secrets Manager and SSM Parameter Store. Two kinds, one file: they
 * share the credential resolution and the SigV4 signing. */
Definition *sek_plugin_awssecrets(void);
Definition *sek_plugin_awsparams(void);

/* Google Secret Manager, with metadata-server login. */
Definition *sek_plugin_gcpsecrets(void);

/* Azure Key Vault, with client-credential or IMDS login. */
Definition *sek_plugin_azuresecrets(void);

/* 1Password Connect. */
Definition *sek_plugin_onepassword(void);

/* Doppler. */
Definition *sek_plugin_doppler(void);

/* Infisical, with universal-auth login. */
Definition *sek_plugin_infisical(void);

/* SecretSpec, through its CLI. */
Definition *sek_plugin_secretspec(void);

/* ---- the full set -------------------------------------------------- */

/* Every plugin this library ships, in one call. Answers the count and
 * points `*out` at a static array of the ten definitions.
 *
 * IT IS ALSO THE THING TO AVOID IF SIZE MATTERS. Naming this pulls every
 * plugin object into the link - request signing and eight HTTP clients
 * included - which is the cost the split exists to remove. It exists for
 * the callers that genuinely want all ten: the CLI, the conformance
 * suite, an app whose chain is decided at run time. */
size_t sek_allplugins(Definition ***out);

/* ---- transport ----------------------------------------------------- */

/* One HTTP round-trip, published because a C consumer has no HTTP client
 * of its own to reach the API it just fetched a token for - and the CLI
 * every port ships is exactly such a consumer. Every other port calls its
 * platform's client here.
 *
 * It is on the PLUGIN side because it is what a plugin is: a socket and a
 * TLS handshake. A chain of built-ins links none of it.
 *
 * https is verified: chain, hostname, SNI, and `SEKRETO_CA_BUNDLE` for
 * extra roots. A non-2xx status is returned rather than raised. */
sek_err sek_fetch(sek_pool *pool, const char *method, const char *url, const sek_map *headers,
                  const char *body, int *status, char **out);

/* RFC 3986 escaping, stricter than any stdlib encoder. With the transport
 * rather than with the signer: four stores that hash nothing build their
 * URLs with it. */
char *sek_uriescape(sek_pool *pool, const char *text);

/* ---- sigv4 --------------------------------------------------------- */

/* One request to sign. `datetime` is `YYYYMMDDTHHMMSSZ` and it is the
 * caller's, so signing is a pure function of its input - which is what
 * lets the shared spec carry known-answer cases. */
typedef struct {
  const char *method;
  const char *url;
  const char *service;
  const char *region;
  const char *keyid;
  const char *secret;
  const char *datetime;
  sek_map *headers;
  const char *body;
  const char *session;
} sek_signing;

/* The headers to attach: authorization, x-amz-date, and
 * x-amz-security-token when a session was given, in that order.
 *
 * It moved here with the aws plugin, and the core of no port imports a
 * hash function any more. */
sek_map *sek_sigv4(sek_pool *pool, const sek_signing *input);

#endif /* VOXGIG_SEKRETO_PLUGINS_H */
