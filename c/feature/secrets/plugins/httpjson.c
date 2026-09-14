// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/httpjson.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Just enough HTTP to ask a vault for a secret: the shared HTTP-JSON
 * helper every store above it is written against.
 *
 * It lives under `plugins/` with the stores that use it, because a chain
 * of the four built-in kinds must never link a socket. `sek_fetch` is
 * published from here rather than from the core for the same reason: the
 * CLI needs an HTTP client to call the API it just fetched a token for,
 * and every other port reaches for its platform's.
 *
 * C has no HTTP client, so this speaks HTTP/1.1 over a POSIX socket
 * directly: a GET or POST with headers and an optional body, a status
 * line, and a response body delimited by Content-Length, by chunks, or by
 * the connection closing. https hands the connected socket to tls.c and
 * then speaks exactly the same framing over it.
 *
 * The framing is hand-rolled and stays hand-rolled: the dependency
 * exception covers cryptographic transport, and HTTP is not that. This is
 * also why the binding is OpenSSL rather than libcurl - libcurl is an
 * HTTP client, and taking it would carry the framing across the line the
 * rule draws.
 *
 * It is not a general-purpose client, deliberately:
 *
 *   NO REDIRECTS. A followed redirect carries X-Vault-Token to a host
 *   checkaddr never saw, and can downgrade https to http.
 *
 *   NO PROXIES. http_proxy in an environment has sent a Vault token in
 *   the clear before, and the GCP and Azure metadata endpoints are not
 *   loopback, so a blanket proxy would capture them too.
 *
 *   NO KEEP-ALIVE, no client certificates, no cookies.
 *
 * A port of rust/src/http.rs.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "support.h"

/* A url split into the parts a request needs. */
typedef struct {
  char *host;      /* bare: what is connected to and what the certificate
                    * is checked against; an IPv6 literal without its
                    * brackets. */
  char *authority; /* as it goes in `Host:`; an IPv6 literal keeps its
                    * brackets, because `Host: 2001:db8::1:8200` is not a
                    * valid authority. */
  int port;
  char *path;
  int tls;
} target;

static sek_err split(sek_pool *pool, const char *url, target *out) {
  const char *rest;
  const char *slash;
  char *authority;
  const char *colon;
  int defaultport;

  if (sek_has_prefix(url, "https://")) {
    rest = url + 8;
    out->tls = 1;
    defaultport = 443;
  } else if (sek_has_prefix(url, "http://")) {
    rest = url + 7;
    out->tls = 0;
    defaultport = 80;
  } else {
    return sek_fmt(pool, "sekreto: not an http url: %s", sek_bareurl(pool, url));
  }

  slash = strchr(rest, '/');
  if (NULL == slash) {
    authority = sek_strdup(pool, rest);
    out->path = sek_strdup(pool, "/");
  } else {
    authority = sek_strndup(pool, rest, (size_t)(slash - rest));
    out->path = sek_strdup(pool, slash);
  }

  out->port = defaultport;

  /* Searched from the RIGHT, so an IPv6 literal's own colons are not read
   * as a port separator. */
  colon = strrchr(authority, ':');
  if (NULL != colon && '\0' != colon[1] && '\0' != authority[0] &&
      ']' != authority[strlen(authority) - 1]) {
    char *stop = NULL;
    long port = strtol(colon + 1, &stop, 10);

    if (NULL == stop || '\0' != *stop || 0 >= port || 65535 < port) {
      return sek_fmt(pool, "sekreto: bad port: %s", sek_bareurl(pool, url));
    }

    out->port = (int)port;
    authority = sek_strndup(pool, authority, (size_t)(colon - authority));
  }

  {
    size_t len = strlen(authority);
    if (2 <= len && '[' == authority[0] && ']' == authority[len - 1]) {
      out->host = sek_strndup(pool, authority + 1, len - 2);
      out->authority = authority;
    } else {
      out->host = authority;
      /* Re-bracketed only if it really is an IPv6 literal. */
      out->authority = NULL != strchr(authority, ':') ? sek_fmt(pool, "[%s]", authority)
                                                      : authority;
    }
  }

  return NULL;
}

/* Connect within one shared deadline.
 *
 * The bound is on the WHOLE attempt, not on each address. A name commonly
 * resolves to several - a dual-stack host answers with both an A and an
 * AAAA - and giving each the full ten seconds makes the real bound ten
 * seconds times however many addresses the name cares to return, which is
 * not a bound at all when the name is the attacker's.
 *
 * A blocking connect() has no bound of its own: against an address that
 * swallows SYNs it blocks for however long the kernel retries, which on
 * Linux is a little over two minutes. So the socket is put in
 * non-blocking mode, connect() is started, and poll() carries what is
 * left of the deadline. */
static sek_err dial(sek_pool *pool, const target *to, const char *url, long long deadline,
                    int *out) {
  struct addrinfo hints;
  struct addrinfo *found = NULL;
  struct addrinfo *at;
  char service[16];
  int code;
  const char *last = "no address";

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  snprintf(service, sizeof(service), "%d", to->port);

  code = getaddrinfo(to->host, service, &hints, &found);
  if (0 != code) {
    return sek_fmt(pool, "sekreto: cannot reach %s: %s", sek_bareurl(pool, url),
                   gai_strerror(code));
  }

  for (at = found; NULL != at; at = at->ai_next) {
    int fd;
    long long left = deadline - sek_nowms();
    int flags;

    if (0 >= left) {
      last = "timed out";
      break;
    }

    fd = socket(at->ai_family, at->ai_socktype, at->ai_protocol);
    if (0 > fd) {
      last = strerror(errno);
      continue;
    }

    flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    if (0 == connect(fd, at->ai_addr, at->ai_addrlen)) {
      fcntl(fd, F_SETFL, flags);
      freeaddrinfo(found);
      *out = fd;
      return NULL;
    }

    if (EINPROGRESS == errno) {
      struct pollfd waiting;
      int ready;

      waiting.fd = fd;
      waiting.events = POLLOUT;
      waiting.revents = 0;

      ready = poll(&waiting, 1, (int)left);

      if (0 < ready) {
        int problem = 0;
        socklen_t size = sizeof(problem);

        if (0 == getsockopt(fd, SOL_SOCKET, SO_ERROR, &problem, &size) && 0 == problem) {
          fcntl(fd, F_SETFL, flags);
          freeaddrinfo(found);
          *out = fd;
          return NULL;
        }

        last = 0 == problem ? "connection failed" : strerror(problem);
      } else if (0 == ready) {
        last = "timed out";
      } else {
        last = strerror(errno);
      }
    } else {
      last = strerror(errno);
    }

    close(fd);
  }

  freeaddrinfo(found);

  return sek_fmt(pool, "sekreto: cannot reach %s: %s", sek_bareurl(pool, url), last);
}

/* Both transports behind one pair of calls, so the framing below is
 * written once. */
typedef struct {
  int fd;
  sek_tls_conn *tls;
} channel;

static sek_err sendall(channel *ch, const char *data, size_t len) {
  size_t at = 0;

  while (at < len) {
    long wrote;

    if (NULL != ch->tls) {
      sek_err err = NULL;
      wrote = sek_tls_write(ch->tls, data + at, len - at, &err);
      if (0 > wrote) {
        return NULL == err ? "write failed" : err;
      }
    } else {
      ssize_t got = send(ch->fd, data + at, len - at, 0);
      if (0 > got) {
        if (EINTR == errno) {
          continue;
        }
        return strerror(errno);
      }
      wrote = (long)got;
    }

    at += (size_t)wrote;
  }

  return NULL;
}

static long receive(channel *ch, char *data, size_t len, sek_err *err) {
  if (NULL != ch->tls) {
    return sek_tls_read(ch->tls, data, len, err);
  }

  for (;;) {
    ssize_t got = recv(ch->fd, data, len, 0);

    if (0 <= got) {
      return (long)got;
    }
    if (EINTR == errno) {
      continue;
    }

    *err = strerror(errno);
    return -1;
  }
}

static const char *findbytes(const char *hay, size_t haylen, const char *needle, size_t len) {
  size_t index;

  if (haylen < len) {
    return NULL;
  }

  for (index = 0; index + len <= haylen; index++) {
    if (0 == memcmp(hay + index, needle, len)) {
      return hay + index;
    }
  }

  return NULL;
}

/* Join a chunked body back together: a hex length (any `;`-separated
 * extension dropped), CRLF, that many BYTES, CRLF; a zero length ends the
 * body and any trailer is ignored.
 *
 * Bytes, not characters. A chunk length counts bytes and a boundary may
 * fall inside a multibyte character, so a secret with any non-ASCII
 * character in it would otherwise come back mangled or take the process
 * down. */
static int dechunk(sek_pool *pool, const char *raw, size_t len, sek_buf *out) {
  const char *rest = raw;
  size_t left = len;

  sek_buf_init(out, pool);

  for (;;) {
    const char *crlf = findbytes(rest, left, "\r\n", 2);
    char *header;
    char *stop = NULL;
    unsigned long size;
    size_t headlen;

    if (NULL == crlf) {
      return 0;
    }

    headlen = (size_t)(crlf - rest);
    header = sek_strndup(pool, rest, headlen);
    {
      char *semi = strchr(header, ';');
      if (NULL != semi) {
        *semi = '\0';
      }
    }

    size = strtoul(header, &stop, 16);
    if (stop == header) {
      return 0;
    }

    left -= headlen + 2;
    rest = crlf + 2;

    if (0 == size) {
      return 1;
    }

    if (left < size) {
      return 0;
    }

    sek_buf_addn(out, rest, size);

    if (left < size + 2) {
      return 0;
    }

    rest += size + 2;
    left -= size + 2;
  }
}

sek_err sek_http(sek_pool *pool, const char *method, const char *url, const sek_map *headers,
                 const char *body, sek_response *out) {
  target to;
  sek_err err;
  channel ch;
  int fd = -1;
  long long deadline = sek_nowms() + SEK_TIMEOUT_MS;
  sek_buf request;
  sek_buf raw;
  const char *split_at;
  char *head;
  size_t index;
  int chunked = 0;
  const char *bare = sek_bareurl(pool, url);

  memset(&to, 0, sizeof(to));
  memset(&ch, 0, sizeof(ch));
  out->status = 0;
  out->body = NULL;
  out->bodylen = 0;

  err = split(pool, url, &to);
  if (NULL != err) {
    return err;
  }

  err = dial(pool, &to, url, deadline, &fd);
  if (NULL != err) {
    return err;
  }

  /* The read and write halves are both bounded. Only bounding the read
   * leaves a write blocked forever once the peer's receive window fills
   * and it stops reading. */
  {
    struct timeval bound;
    bound.tv_sec = SEK_TIMEOUT_MS / 1000;
    bound.tv_usec = (SEK_TIMEOUT_MS % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &bound, sizeof(bound));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &bound, sizeof(bound));
  }

  ch.fd = fd;

  if (to.tls) {
    if (!sek_tls_available()) {
      close(fd);
      return sek_fmt(pool, "sekreto: cannot reach %s: this build has no TLS backend", bare);
    }

    err = sek_tls_open(pool, fd, to.host, &ch.tls);
    if (NULL != err) {
      close(fd);
      /* A handshake failure is a refusal to TRUST the server, so it
       * surfaces as an error and never as a missing secret. */
      return sek_fmt(pool, "sekreto: cannot reach %s: %s", bare, err);
    }
  }

  /* A default port stays implicit in the Host header, the way a URL
   * normalises it: a SigV4 signature covers `host`, and `Host: x:443` is
   * not what was signed. */
  sek_buf_init(&request, pool);
  sek_buf_addfmt(&request, "%s %s HTTP/1.1\r\n", method, to.path);
  if ((to.tls && 443 == to.port) || (!to.tls && 80 == to.port)) {
    sek_buf_addfmt(&request, "Host: %s\r\n", to.authority);
  } else {
    sek_buf_addfmt(&request, "Host: %s:%d\r\n", to.authority, to.port);
  }
  sek_buf_add(&request, "Accept: application/json\r\n");
  sek_buf_add(&request, "Connection: close\r\n");

  if (NULL != headers) {
    for (index = 0; index < headers->len; index++) {
      sek_buf_addfmt(&request, "%s: %s\r\n", headers->keys[index], headers->vals[index]);
    }
  }

  if (NULL != body) {
    sek_buf_addfmt(&request, "Content-Length: %lu\r\n", (unsigned long)strlen(body));
  }

  sek_buf_add(&request, "\r\n");

  if (NULL != body) {
    sek_buf_add(&request, body);
  }

  err = sendall(&ch, request.data, request.len);
  if (NULL != err) {
    sek_tls_close(ch.tls);
    close(fd);
    return sek_fmt(pool, "sekreto: cannot reach %s: %s", bare, err);
  }

  /* Bounded, not read-to-end: an endless body would otherwise be
   * accumulated in memory until the deadline, which on a loopback or
   * datacentre link is gigabytes. One byte over the bound is enough to
   * know it was exceeded, and an endless body is a store that could not
   * answer - so this is an error, never a miss. */
  sek_buf_init(&raw, pool);
  for (;;) {
    char chunk[16384];
    sek_err why = NULL;
    long got;

    if (sek_nowms() > deadline) {
      sek_tls_close(ch.tls);
      close(fd);
      return sek_fmt(pool, "sekreto: cannot reach %s: timed out", bare);
    }

    got = receive(&ch, chunk, sizeof(chunk), &why);

    if (0 > got) {
      sek_tls_close(ch.tls);
      close(fd);
      return sek_fmt(pool, "sekreto: cannot reach %s: %s", bare, NULL == why ? "read failed" : why);
    }

    if (0 == got) {
      break;
    }

    sek_buf_addn(&raw, chunk, (size_t)got);

    if (SEK_MAXBODY < raw.len) {
      sek_tls_close(ch.tls);
      close(fd);
      return sek_fmt(pool, "sekreto: oversized response from %s", bare);
    }
  }

  sek_tls_close(ch.tls);
  close(fd);

  split_at = findbytes(raw.data, raw.len, "\r\n\r\n", 4);
  if (NULL == split_at) {
    return sek_fmt(pool, "sekreto: malformed response from %s", bare);
  }

  /* Headers are ASCII; the body is not necessarily, so it stays bytes
   * until every length-counted slice has been taken. */
  head = sek_strndup(pool, raw.data, (size_t)(split_at - raw.data));

  {
    /* "HTTP/1.1 200 OK" - the status is the second whitespace-separated
     * field of the first line. */
    const char *space = strchr(head, ' ');
    if (NULL == space) {
      return sek_fmt(pool, "sekreto: malformed response from %s", bare);
    }
    out->status = (int)strtol(space + 1, NULL, 10);
    if (0 == out->status) {
      return sek_fmt(pool, "sekreto: malformed response from %s", bare);
    }
  }

  {
    /* transfer-encoding, matched case-insensitively on both halves: a
     * vault answering from a store usually chunks. */
    char *lowered = sek_lowercase(pool, head);
    char *line = strstr(lowered, "\ntransfer-encoding:");
    if (NULL != line && NULL != strstr(line, "chunked")) {
      const char *stop = strchr(line + 1, '\n');
      char *value = NULL == stop ? sek_strdup(pool, line + 1)
                                 : sek_strndup(pool, line + 1, (size_t)(stop - line - 1));
      chunked = sek_contains(value, "chunked");
    }
  }

  {
    const char *rawbody = split_at + 4;
    size_t bodylen = raw.len - (size_t)(rawbody - raw.data);

    if (chunked) {
      sek_buf joined;
      if (!dechunk(pool, rawbody, bodylen, &joined)) {
        return sek_fmt(pool, "sekreto: malformed response from %s", bare);
      }
      out->body = joined.data;
      out->bodylen = joined.len;
    } else {
      out->body = sek_strndup(pool, rawbody, bodylen);
      out->bodylen = bodylen;
    }
  }

  return NULL;
}

sek_err sek_fetchjson(sek_pool *pool, const char *method, const char *url, const sek_map *headers,
                      const char *body, sek_answer *out) {
  sek_response res;
  sek_err err = sek_http(pool, method, url, headers, body, &res);

  out->status = 0;
  out->body = NULL;

  if (NULL != err) {
    return err;
  }

  out->status = res.status;
  out->body = sek_json_parse(pool, res.body);

  /* A success status promised JSON. A body that does not parse means the
   * store could not answer coherently, and treating that as a miss would
   * fall through to a weaker store. Error statuses may carry any body -
   * they are decided on status alone. */
  if (200 == res.status && NULL == out->body) {
    return sek_fmt(pool, "sekreto: malformed response from %s", sek_bareurl(pool, url));
  }

  return NULL;
}

/* The published round-trip. Thin on purpose: a consumer gets the status
 * and the body and decides for itself, exactly as the providers do. */
sek_err sek_fetch(sek_pool *pool, const char *method, const char *url, const sek_map *headers,
                  const char *body, int *status, char **out) {
  sek_response res;
  sek_err err = sek_http(pool, method, url, headers, body, &res);

  *status = 0;
  *out = NULL;

  if (NULL != err) {
    return err;
  }

  *status = res.status;
  *out = res.body;

  return NULL;
}
