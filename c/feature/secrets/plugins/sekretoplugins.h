// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (c/plugins/sekretoplugins.h)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The eleven provider kinds that are NOT built in, each a voxgig/plugin
 * definition, plus the transport and the SigV4 signing that come with
 * them.
 *
 * What makes a kind a plugin is that it needs more of the platform than a
 * local file: a socket, a signature or a child process. A chain of the
 * four built-in kinds links none of this, which is the whole point of the
 * split (docs/design/plugin-providers.md).
 *
 * LINKING IS THE BOUNDARY, AND A HEADER IS NOT LINKING. Declaring all
 * eleven
 * here costs a consumer nothing: what a binary carries is the objects its
 * link line names. A lean consumer links `plugins/hashicorp.o` and the
 * transport it needs, hands `sek_plugin_hashicorp()` to sek_options, and
 * never has AWS request signing, seven other vault clients or the child
 * process launcher in its binary. `sek_allplugins` is the opposite trade
 * and the honest one: it names all eleven, so an object referencing it pulls
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

/* A mini vault: every secret a project owns, encrypted, in one file. A
 * plugin because it needs crypto, which is the line the four built-in
 * kinds stay behind. Its own API is below. */
Definition *sek_plugin_minivault(void);

/* ---- the mini vault ------------------------------------------------ */

/* A chain READS; writing is a deliberate act with an API of its own, so
 * the `minivault` definition publishes `vault` beside `provider` and
 * `sek_vaultof` reads it back off the host. The handle is opaque: what a
 * key may do is what the file says, and a caller holding the struct it
 * is recorded in could flip its own permission.
 *
 * Everything here is pool-owned, like the rest of this library: a vault
 * dies with the pool it was opened from. */
typedef struct sek_minivault sek_minivault;

/* The key id a vault gets when a caller names none. */
#define SEK_VAULT_MASTERKEY "master"

/* The PBKDF2-HMAC-SHA256 round count when a caller names none. */
#define SEK_VAULT_ITERATIONS 210000

/* The export key the vault API is published under, beside the `provider`
 * key every kind publishes. */
#define SEK_VAULT_EXPORT "vault"

/* What a key may do. `grants` is empty for a master key, which reads and
 * writes every name there is; it is sorted, and every read of it answers
 * with a COPY, so what a caller is handed cannot become what the vault
 * believes. */
typedef struct {
  const char *key;
  int master;
  int write;
  sek_list *grants;
} sek_vaultinfo;

/* How a vault file is opened as one key. */
typedef struct {
  /* The vault file. */
  const char *file;
  /* Which key to open with. NULL means SEK_VAULT_MASTERKEY. */
  const char *key;
  /* What unwraps that key. */
  const char *passphrase;
  /* The PBKDF2 round count used when this handle CREATES a key. Reading
   * uses what the file records for the key being opened. Zero means the
   * library default. */
  int iterations;
  /* Make the file, with this key as its master, if it is not there.
   *
   * Off by default. A missing vault is far more often a broken
   * deployment than a new one, and a store that invents itself where a
   * real vault was meant to be answers every read with a miss. */
  int create;
} sek_vaultoptions;

/* What mints a restricted key. */
typedef struct {
  /* The id the new key answers to. */
  const char *key;
  /* What unwraps it. Nothing else does, and no master can recover it - a
   * lost restricted passphrase is re-granted, never read back. */
  const char *passphrase;
  /* The names the key may read. A name that does not exist yet is
   * allowed and means what it says: the key reads it once a master
   * writes it. */
  sek_list *names;
  /* Whether it may overwrite the values it can read. */
  int write;
  /* PBKDF2 rounds for this key, defaulting to the opening handle's. */
  int iterations;
} sek_vaultgrant;

/* Open a vault file as one key.
 *
 * The handle is LAZY. Nothing is read, and no passphrase is stretched,
 * until a call needs the file - so putting a vault in a chain of ten
 * providers costs ten objects rather than ten PBKDF2 runs. */
sek_err sek_vault_open(sek_pool *pool, const sek_vaultoptions *options, sek_minivault **out);

/* Make a vault file and answer a handle on its master key.
 *
 * Refuses a file that is already there: a vault is created once, and
 * overwriting one discards every secret in it along with every key that
 * could read them. */
sek_err sek_vault_create(sek_pool *pool, const sek_vaultoptions *options, sek_minivault **out);

const char *sek_vault_file(sek_minivault *vault);
const char *sek_vault_key(sek_minivault *vault);

/* Derive the key and read the file NOW rather than at first use. */
sek_err sek_vault_info(sek_minivault *vault, sek_vaultinfo **out);

/* Forget the derived keys. The next call opens again. */
void sek_vault_close(sek_minivault *vault);

/* The names this key can read, sorted. */
sek_err sek_vault_list(sek_minivault *vault, sek_list **out);

/* The value, or a MISS (`*out == NULL`). A name the vault does not hold
 * and a name this key was not granted are both a miss. */
sek_err sek_vault_get(sek_minivault *vault, const char *name, char **out);
sek_err sek_vault_has(sek_minivault *vault, const char *name, int *out);

/* Write a value. A master writes any name; a restricted key holding
 * `write` overwrites the names it was granted, and creates none. */
sek_err sek_vault_set(sek_minivault *vault, const char *name, const char *value);

/* Drop a name. Master only. */
sek_err sek_vault_remove(sek_minivault *vault, const char *name);

/* Every key in the file, with what it may do. Master only. */
sek_err sek_vault_keys(sek_minivault *vault, sek_vaultinfo ***out, size_t *count);

/* Mint a restricted key. Master only. */
sek_err sek_vault_grant(sek_minivault *vault, const sek_vaultgrant *spec);

/* Drop a key. Master only.
 *
 * Anyone who already copied the file keeps whatever that key could read,
 * so revoking bars future reads of the LIVE file and `sek_vault_rotate`
 * is what takes a secret back. */
sek_err sek_vault_revoke(sek_minivault *vault, const char *key);

/* Take a new root key, re-encrypt every value under it, and DROP EVERY
 * OTHER KEY. Master only.
 *
 * The other keys go because they must: their rings are sealed under
 * passphrases this process does not have, so there is no way to hand
 * them keys they can unwrap. Re-grant afterwards. */
sek_err sek_vault_rotate(sek_minivault *vault);

/* The vault behind a store in a chain, as its programmatic API. A NULL
 * or empty `store` takes the unqualified alias: one vault in the chain
 * resolves whatever it is called, and two refuse rather than picking
 * one. */
sek_err sek_vaultof(sek_pool *pool, sek_sekreto *sek, const char *store, sek_minivault **out);

/* ---- the full set -------------------------------------------------- */

/* Every plugin this library ships, in one call. Answers the count and
 * points `*out` at a static array of the eleven definitions.
 *
 * IT IS ALSO THE THING TO AVOID IF SIZE MATTERS. Naming this pulls every
 * plugin object into the link - request signing, eight HTTP clients and
 * an AEAD included - which is the cost the split exists to remove. It
 * exists for the callers that genuinely want all eleven: the CLI, the
 * conformance suite, an app whose chain is decided at run time. */
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
