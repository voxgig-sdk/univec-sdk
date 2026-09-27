(* VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (ocaml/plugins/minivault_stubs.c) *)
(* Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
/* The four primitives the mini vault is made of: AES-256-GCM,
 * PBKDF2-HMAC-SHA256, HMAC-SHA256, and the entropy under them.
 *
 * THE SECOND FILE IN THIS PORT THAT NAMES OpenSSL, and the only other
 * one. `tls_stubs.c` is the first, and its note says the exception the
 * link is taken under covered TRANSPORT only. AGENTS.md now says
 * cryptography, because a block cipher protecting secrets AT REST has
 * properties no known-answer vector can check - a table-driven AES
 * passes every vector in the world and still hands its key to anyone who
 * can time a cache. The in-tree SHA-256 and HMAC in `crypto.ml` stay
 * where they are, as the widened rule says outright: they work, a SigV4
 * signature is a chain of them so one wrong bit fails the published
 * vectors loudly, and rewriting them buys nothing.
 *
 * WHY C AT ALL. OCaml's distribution has no cryptographic digest but MD5
 * and no cipher at all, and the no-new-package rule stands, so the
 * primitives come from the library this port already links. `plugins/
 * minivault.ml` is the whole OCaml side and holds every decision about
 * the format; this file does the four calls and nothing else.
 *
 * Bytes travel as OCaml STRINGS, which are byte sequences and may hold
 * NULs - so every length here comes from `caml_string_length` and never
 * from `strlen`. A failure raises `Failure`, which the OCaml side turns
 * into the library's own error.
 */

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>

#include <string.h>

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>

#define SEK_MV_KEYLEN 32
#define SEK_MV_IVLEN 12
#define SEK_MV_TAGLEN 16

/* Fresh entropy from the platform's CSPRNG. A nonce repeated under one
 * AES-GCM key loses the confidentiality of both messages, so a failure
 * here is raised rather than papered over. */
CAMLprim value sekreto_mv_random(value vlen)
{
  CAMLparam1(vlen);
  CAMLlocal1(out);

  const int len = Int_val(vlen);

  if (0 > len) {
    caml_failwith("sekreto: minivault: a negative length");
  }

  out = caml_alloc_string((mlsize_t) len);

  if (0 < len && 1 != RAND_bytes((unsigned char *) Bytes_val(out), len)) {
    caml_failwith("sekreto: minivault: no randomness available");
  }

  CAMLreturn(out);
}

/* HMAC-SHA256 of `msg` under `key`. */
CAMLprim value sekreto_mv_hmac(value vkey, value vmsg)
{
  CAMLparam2(vkey, vmsg);
  CAMLlocal1(out);

  unsigned char mac[EVP_MAX_MD_SIZE];
  unsigned int len = 0;

  if (NULL == HMAC(EVP_sha256(), String_val(vkey), (int) caml_string_length(vkey),
                   (const unsigned char *) String_val(vmsg), caml_string_length(vmsg), mac,
                   &len)) {
    caml_failwith("sekreto: minivault: cannot compute a mac");
  }

  out = caml_alloc_initialized_string((mlsize_t) len, (const char *) mac);

  CAMLreturn(out);
}

/* PBKDF2-HMAC-SHA256.
 *
 * A round count below one is refused here rather than passed on: it is
 * what a damaged or hostile file records to make the derivation free, and
 * OpenSSL would accept it. */
CAMLprim value sekreto_mv_pbkdf2(value vpass, value vsalt, value viters, value vlen)
{
  CAMLparam4(vpass, vsalt, viters, vlen);
  CAMLlocal1(out);

  const int iters = Int_val(viters);
  const int len = Int_val(vlen);

  if (1 > iters) {
    caml_failwith("sekreto: minivault: unusable round count");
  }
  if (0 >= len) {
    caml_failwith("sekreto: minivault: a bad key length");
  }

  out = caml_alloc_string((mlsize_t) len);

  if (1 != PKCS5_PBKDF2_HMAC(String_val(vpass), (int) caml_string_length(vpass),
                             (const unsigned char *) String_val(vsalt),
                             (int) caml_string_length(vsalt), iters, EVP_sha256(), len,
                             (unsigned char *) Bytes_val(out))) {
    caml_failwith("sekreto: minivault: cannot derive a key");
  }

  CAMLreturn(out);
}

/* AES-256-GCM, sealing. The answer is ciphertext followed by the 16-byte
 * tag, which is where every other port's AEAD leaves it and therefore
 * what the format records. */
CAMLprim value sekreto_mv_seal(value vkey, value viv, value vplain, value vaad)
{
  CAMLparam4(vkey, viv, vplain, vaad);
  CAMLlocal1(out);

  EVP_CIPHER_CTX *ctx = NULL;
  const size_t plainlen = caml_string_length(vplain);
  unsigned char *raw = NULL;
  int len = 0;
  int ok = 0;

  if (SEK_MV_KEYLEN != caml_string_length(vkey) || SEK_MV_IVLEN != caml_string_length(viv)) {
    caml_failwith("sekreto: minivault: bad key");
  }

  out = caml_alloc_string((mlsize_t) (plainlen + SEK_MV_TAGLEN));
  raw = (unsigned char *) Bytes_val(out);

  ctx = EVP_CIPHER_CTX_new();
  if (NULL == ctx) {
    caml_failwith("sekreto: minivault: cannot seal");
  }

  ok = 1 == EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, SEK_MV_IVLEN, NULL) &&
       1 == EVP_EncryptInit_ex(ctx, NULL, NULL, (const unsigned char *) String_val(vkey),
                               (const unsigned char *) String_val(viv)) &&
       1 == EVP_EncryptUpdate(ctx, NULL, &len, (const unsigned char *) String_val(vaad),
                              (int) caml_string_length(vaad)) &&
       1 == EVP_EncryptUpdate(ctx, raw, &len, (const unsigned char *) String_val(vplain),
                              (int) plainlen) &&
       1 == EVP_EncryptFinal_ex(ctx, raw + len, &len) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, SEK_MV_TAGLEN, raw + plainlen);

  EVP_CIPHER_CTX_free(ctx);

  if (!ok) {
    caml_failwith("sekreto: minivault: cannot seal");
  }

  CAMLreturn(out);
}

/* AES-256-GCM, opening.
 *
 * A tag that fails to verify raises, and the OCaml side turns that into
 * the message the format's contract names. The tag is the only evidence
 * there is, and it cannot tell a wrong passphrase from a damaged file. */
CAMLprim value sekreto_mv_unseal(value vkey, value viv, value vblob, value vaad)
{
  CAMLparam4(vkey, viv, vblob, vaad);
  CAMLlocal1(out);

  EVP_CIPHER_CTX *ctx = NULL;
  const size_t bloblen = caml_string_length(vblob);
  const unsigned char *blob = (const unsigned char *) String_val(vblob);
  size_t cut = 0;
  unsigned char *raw = NULL;
  int len = 0;
  int ok = 0;

  if (SEK_MV_KEYLEN != caml_string_length(vkey) || SEK_MV_IVLEN != caml_string_length(viv)) {
    caml_failwith("sekreto: minivault: bad key");
  }
  if (SEK_MV_TAGLEN > bloblen) {
    caml_failwith("sekreto: minivault: truncated");
  }

  cut = bloblen - SEK_MV_TAGLEN;
  out = caml_alloc_string((mlsize_t) cut);
  raw = (unsigned char *) Bytes_val(out);

  /* Re-read after the allocation: caml_alloc_string may move the heap,
   * and `blob` points into an OCaml string. */
  blob = (const unsigned char *) String_val(vblob);

  ctx = EVP_CIPHER_CTX_new();
  if (NULL == ctx) {
    caml_failwith("sekreto: minivault: cannot open");
  }

  ok = 1 == EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, SEK_MV_IVLEN, NULL) &&
       1 == EVP_DecryptInit_ex(ctx, NULL, NULL, (const unsigned char *) String_val(vkey),
                               (const unsigned char *) String_val(viv)) &&
       1 == EVP_DecryptUpdate(ctx, NULL, &len, (const unsigned char *) String_val(vaad),
                              (int) caml_string_length(vaad)) &&
       1 == EVP_DecryptUpdate(ctx, raw, &len, blob, (int) cut) &&
       1 == EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, SEK_MV_TAGLEN,
                                (void *) (blob + cut)) &&
       0 < EVP_DecryptFinal_ex(ctx, raw + len, &len);

  EVP_CIPHER_CTX_free(ctx);

  if (!ok) {
    caml_failwith("sekreto: minivault: cannot open");
  }

  CAMLreturn(out);
}
