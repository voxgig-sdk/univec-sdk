// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Tls.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Tls.hpp"

#include <arpa/inet.h>
#include <errno.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <unistd.h>

#include <cstdlib>
#include <fstream>
#include <sstream>

#include "Crypto.hpp"

namespace sekreto {

namespace {

/// What OpenSSL has to say for itself, never the empty string - an error
/// message reading "cannot reach https://vault: " says nothing at all.
std::string sslwhy() {
  unsigned long code = ERR_get_error();

  if (0 == code) return "handshake failed";

  char buf[256];
  ERR_error_string_n(code, buf, sizeof(buf));

  // Drain the rest, so a later failure does not report this one's.
  while (0 != ERR_get_error()) {
  }

  return buf;
}

/// Is this an IP literal rather than a DNS name? The two are verified
/// differently, and getting it wrong is the half people forget.
bool isipliteral(const std::string& host) {
  unsigned char scratch[16];

  if (0 < inet_pton(AF_INET, host.c_str(), scratch)) return true;
  if (0 < inet_pton(AF_INET6, host.c_str(), scratch)) return true;

  return false;
}

/// Extra trust roots from SEKRETO_CA_BUNDLE, added to the store the system
/// roots are already in.
///
/// ADDITIVE, never a replacement: an internal Vault behind a private CA is
/// the common case, and an application must not lose the public roots by
/// naming one. FAILS OPEN, silently: an unreadable file, or a certificate
/// the store rejects, adds no roots and raises nothing - a wrong path
/// weakens nothing that was already trusted.
///
/// The PEM is parsed in-tree (Http.cpp) and only the DER is handed over,
/// because reading a text file is not cryptographic transport.
void addbundle(SSL_CTX* ctx) {
  const char* path = std::getenv(CABUNDLE);

  if (nullptr == path || '\0' == path[0]) return;

  std::ifstream handle(path, std::ios::binary);
  if (!handle) return;

  std::stringstream buffer;
  buffer << handle.rdbuf();

  X509_STORE* store = SSL_CTX_get_cert_store(ctx);
  if (nullptr == store) return;

  for (const std::string& der : pemcerts(buffer.str())) {
    const unsigned char* raw = reinterpret_cast<const unsigned char*>(der.data());
    X509* cert = d2i_X509(nullptr, &raw, static_cast<long>(der.size()));

    if (nullptr == cert) continue;

    X509_STORE_add_cert(store, cert);
    X509_free(cert);
  }
}

class Tlsstream : public Stream {
 public:
  Tlsstream(int fd, SSL_CTX* ctx, SSL* ssl, const std::string& url)
      : fd_(fd), ctx_(ctx), ssl_(ssl), url_(url) {}

  ~Tlsstream() override {
    if (nullptr != ssl_) {
      SSL_shutdown(ssl_);
      SSL_free(ssl_);
    }
    if (nullptr != ctx_) SSL_CTX_free(ctx_);
    if (0 <= fd_) ::close(fd_);
  }

  Tlsstream(const Tlsstream&) = delete;
  Tlsstream& operator=(const Tlsstream&) = delete;

  size_t readsome(char* buf, size_t len) override {
    int got = SSL_read(ssl_, buf, static_cast<int>(len));

    if (0 < got) return static_cast<size_t>(got);

    int reason = SSL_get_error(ssl_, got);

    // A truncated stream is how many servers close; the framing decides
    // whether what arrived was a whole response.
    if (SSL_ERROR_ZERO_RETURN == reason) return 0;

    if (SSL_ERROR_SYSCALL == reason && 0 == ERR_peek_error()) {
      // The socket carries the read deadline, so a stalled server arrives
      // here as EAGAIN. That is a store that could not answer, and reading
      // it as a clean end of stream would hand back a TRUNCATED body -
      // which the JSON parser would then reject as a malformed response,
      // hiding a timeout behind the wrong diagnosis.
      if (EAGAIN == errno || EWOULDBLOCK == errno) {
        throw SekretoError("sekreto: cannot reach " + bareurl(url_) + ": timed out");
      }
      return 0;
    }

    throw SekretoError("sekreto: cannot reach " + bareurl(url_) + ": " + sslwhy());
  }

  void writeall(const char* buf, size_t len) override {
    size_t sent = 0;

    while (sent < len) {
      int put = SSL_write(ssl_, buf + sent, static_cast<int>(len - sent));

      if (0 >= put) {
        throw SekretoError("sekreto: cannot reach " + bareurl(url_) + ": " + sslwhy());
      }

      sent += static_cast<size_t>(put);
    }
  }

 private:
  int fd_;
  SSL_CTX* ctx_;
  SSL* ssl_;
  std::string url_;
};

/// Everything acquired so far, released on any error arm as well as the
/// success one.
struct Setup {
  int fd = -1;
  SSL_CTX* ctx = nullptr;
  SSL* ssl = nullptr;

  ~Setup() {
    if (nullptr != ssl) SSL_free(ssl);
    if (nullptr != ctx) SSL_CTX_free(ctx);
    if (0 <= fd) ::close(fd);
  }

  void keep() {
    fd = -1;
    ctx = nullptr;
    ssl = nullptr;
  }
};

}  // namespace

std::unique_ptr<Stream> tlsstream(int fd, const std::string& host, const std::string& url) {
  Setup held;
  held.fd = fd;

  auto refuse = [&url](const std::string& why) {
    return SekretoError("sekreto: cannot reach " + bareurl(url) + ": " + why);
  };

  held.ctx = SSL_CTX_new(TLS_client_method());
  if (nullptr == held.ctx) throw refuse(sslwhy());

  // TLS 1.0 and 1.1 are withdrawn; a vault that offers only those is not
  // one this library will talk to.
  SSL_CTX_set_min_proto_version(held.ctx, TLS1_2_VERSION);

  // (1) Verify the chain against the system trust store. The default
  // paths also honour SSL_CERT_FILE and SSL_CERT_DIR, and the NULL
  // callback means a verification error ABORTS the handshake rather than
  // being reported and ignored.
  if (1 != SSL_CTX_set_default_verify_paths(held.ctx)) throw refuse(sslwhy());
  SSL_CTX_set_verify(held.ctx, SSL_VERIFY_PEER, nullptr);

  // (4) Extra roots, additively, after the system ones are in place.
  addbundle(held.ctx);

  held.ssl = SSL_new(held.ctx);
  if (nullptr == held.ssl) throw refuse(sslwhy());

  // (2) Verify the HOSTNAME. This is a SEPARATE step from chain
  // verification, and it is the half that gets forgotten: a valid
  // certificate for any host would otherwise be accepted for this one.
  //
  // An IP literal takes the other call. SSL_set1_host does DNS-name
  // matching and will NOT match an iPAddress SAN, so a port that treats
  // every host as a name cannot reach an https endpoint named by address -
  // and, worse, would have to disable verification to do so.
  X509_VERIFY_PARAM* param = SSL_get0_param(held.ssl);
  bool literal = isipliteral(host);

  if (literal) {
    if (1 != X509_VERIFY_PARAM_set1_ip_asc(param, host.c_str())) {
      throw refuse("cannot verify address " + host);
    }
  } else {
    if (1 != SSL_set1_host(held.ssl, host.c_str())) {
      throw refuse("cannot verify host name " + host);
    }

    // (3) SNI - and not for an IP literal, which RFC 6066 forbids and
    // OpenSSL would send anyway if it were handed one.
    SSL_set_tlsext_host_name(held.ssl, host.c_str());
  }

  if (1 != SSL_set_fd(held.ssl, fd)) throw refuse(sslwhy());

  if (1 != SSL_connect(held.ssl)) {
    // The verification reason first, when there is one: "certificate
    // verify failed" alone does not say whether the chain or the HOSTNAME
    // was refused, and those are two different misconfigurations.
    long refused = SSL_get_verify_result(held.ssl);
    if (X509_V_OK != refused) {
      throw refuse(std::string("certificate verify failed: ") +
                   X509_verify_cert_error_string(refused));
    }
    throw refuse(sslwhy());
  }

  // Belt and braces. SSL_VERIFY_PEER already aborts on a bad chain, but
  // the two checks below are cheap and they are what makes "verification
  // is on" observable rather than assumed.
  long verified = SSL_get_verify_result(held.ssl);
  if (X509_V_OK != verified) {
    throw refuse(std::string("certificate verify failed: ") +
                 X509_verify_cert_error_string(verified));
  }

  X509* peer = SSL_get1_peer_certificate(held.ssl);
  if (nullptr == peer) throw refuse("no server certificate");
  X509_free(peer);

  std::unique_ptr<Stream> out(new Tlsstream(held.fd, held.ctx, held.ssl, url));
  held.keep();

  return out;
}

}  // namespace sekreto
