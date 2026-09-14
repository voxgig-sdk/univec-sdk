-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/native/sekretonet.c)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/*
 * sekreto-net: the transport this port does not have.
 *
 * Lua 5.4's whole standard library is basic, coroutine, package, string,
 * utf8, table, math, io, os and debug. There are no sockets of any kind,
 * no TLS, and `io.popen` is unidirectional and goes through a shell. So
 * the two things a Lua program cannot do for itself are done here, in one
 * file, compiled by lua/Makefile:
 *
 *   fetch  connect a TCP socket (optionally TLS), write the bytes the
 *          caller framed, read the bytes back
 *   exec   run a child with an argv ARRAY (never a shell), stdin closed,
 *          stdout and stderr drained concurrently
 *
 * What is NOT here, deliberately: HTTP. The request line, the headers,
 * chunked decoding and the 8 MiB cap are all framed in Lua
 * (src/sekreto/http.lua). This program moves bytes. That keeps the
 * dependency exactly as narrow as AGENTS.md rule 3 allows -
 * cryptographic transport, and nothing else. In particular SHA-256 and
 * HMAC are NOT taken from libcrypto: they are hand-rolled in
 * src/sekreto/crypto.lua, the same decision the rust port took with
 * `ring` already inside rustls's closure.
 *
 * Audit surface: `-lssl -lcrypto`, and the distribution's OpenSSL is the
 * audit surface. Nothing else is linked beyond libc.
 *
 * The four obligations of a TLS binding, all of them met below, because a
 * binding that connects without verifying is worse than no TLS:
 *
 *   1. chain     SSL_CTX_set_default_verify_paths + SSL_VERIFY_PEER, and
 *                SSL_get_verify_result checked afterwards
 *   2. hostname  SSL_set1_host for a DNS name, and
 *                X509_VERIFY_PARAM_set1_ip_asc for an IP literal - which
 *                is a different call, and the half people forget
 *   3. SNI       SSL_set_tlsext_host_name, and NOT for an IP literal
 *                (RFC 6066 forbids it)
 *   4. roots     SEKRETO_CA_BUNDLE, loaded IN ADDITION to the system
 *                store, failing open and silently
 *
 * Invocation: sekreto-net <requestfile>
 *
 * The request arrives in a file rather than on the command line because
 * a vault token rides in the headers and the process table is world
 * readable. The caller creates it 0600; this program unlinks it before
 * reading a byte of it.
 *
 * Wire format, in and out, is length-prefixed and binary safe:
 *
 *   request   <name> <len>\n<len bytes>\n   repeated
 *   answer    OK <len>\n<len bytes>
 *             ERR <len>\n<len bytes>
 *             EXEC <status> <outlen> <errlen>\n<out><err>
 */

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>

#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#define MAXFIELD (16 * 1024 * 1024)

/* ------------------------------------------------------------ buffers */

typedef struct {
  char *data;
  size_t len;
  size_t cap;
} buf;

static void bufinit(buf *b) {
  b->data = NULL;
  b->len = 0;
  b->cap = 0;
}

static int bufput(buf *b, const char *bytes, size_t n) {
  if (b->len + n > b->cap) {
    size_t want = b->cap ? b->cap : 4096;
    char *grown;
    while (want < b->len + n) {
      want *= 2;
    }
    grown = realloc(b->data, want);
    if (NULL == grown) {
      return 0;
    }
    b->data = grown;
    b->cap = want;
  }
  memcpy(b->data + b->len, bytes, n);
  b->len += n;
  return 1;
}

static void buffree(buf *b) {
  free(b->data);
  bufinit(b);
}

/* ------------------------------------------------------------ answers */

static void writeall(int fd, const char *bytes, size_t n) {
  size_t at = 0;
  while (at < n) {
    ssize_t wrote = write(fd, bytes + at, n - at);
    if (0 >= wrote) {
      if (EINTR == errno) {
        continue;
      }
      return;
    }
    at += (size_t)wrote;
  }
}

/* A transport failure. The caller turns this into
 * `sekreto: cannot reach <url>: <message>`. */
static void answererr(const char *message) {
  char head[64];
  int n = snprintf(head, sizeof head, "ERR %zu\n", strlen(message));
  writeall(1, head, (size_t)n);
  writeall(1, message, strlen(message));
  exit(0);
}

static void answerok(const char *bytes, size_t n) {
  char head[64];
  int head_n = snprintf(head, sizeof head, "OK %zu\n", n);
  writeall(1, head, (size_t)head_n);
  writeall(1, bytes, n);
  exit(0);
}

/* The newest OpenSSL diagnostic, so a verification failure says which. */
static void answersslerr(const char *what) {
  char message[512];
  unsigned long code = ERR_peek_last_error();

  if (0 == code) {
    snprintf(message, sizeof message, "%s", what);
  } else {
    char detail[256];
    ERR_error_string_n(code, detail, sizeof detail);
    snprintf(message, sizeof message, "%s: %s", what, detail);
  }

  answererr(message);
}

/* ------------------------------------------------------ request fields */

typedef struct {
  char *name;
  char *value;
  size_t len;
} field;

static field *FIELDS = NULL;
static size_t NFIELDS = 0;

static const char *fieldof(const char *name, const char *fallback) {
  size_t index;
  for (index = 0; index < NFIELDS; index++) {
    if (0 == strcmp(FIELDS[index].name, name)) {
      return FIELDS[index].value;
    }
  }
  return fallback;
}

static long numberof(const char *name, long fallback) {
  const char *text = fieldof(name, NULL);
  if (NULL == text) {
    return fallback;
  }
  return strtol(text, NULL, 10);
}

/* Read the whole request file, then unlink it. */
static void readrequest(const char *path) {
  FILE *handle = fopen(path, "rb");
  buf whole;
  size_t at;

  if (NULL == handle) {
    answererr("cannot read the transport request");
  }

  /* Unlinked immediately: the file carries the vault token. */
  unlink(path);

  bufinit(&whole);

  for (;;) {
    char chunk[65536];
    size_t got = fread(chunk, 1, sizeof chunk, handle);
    if (0 == got) {
      break;
    }
    if (!bufput(&whole, chunk, got)) {
      answererr("out of memory reading the transport request");
    }
  }
  fclose(handle);

  /* Two NUL bytes past the end, not counted, so that the terminator
   * written over each payload's trailing newline is always in bounds. */
  if (!bufput(&whole, "\0\0", 2)) {
    answererr("out of memory reading the transport request");
  }
  whole.len -= 2;

  at = 0;
  while (at < whole.len) {
    char *head = whole.data + at;
    char *nl = memchr(head, '\n', whole.len - at);
    char *space;
    long len;
    field *grown;

    if (NULL == nl) {
      break;
    }

    *nl = '\0';
    space = strchr(head, ' ');
    if (NULL == space) {
      answererr("malformed transport request");
    }
    *space = '\0';

    len = strtol(space + 1, NULL, 10);
    if (0 > len || MAXFIELD < len) {
      answererr("malformed transport request");
    }

    at = (size_t)(nl - whole.data) + 1;
    if (at + (size_t)len > whole.len) {
      answererr("truncated transport request");
    }

    grown = realloc(FIELDS, (NFIELDS + 1) * sizeof(field));
    if (NULL == grown) {
      answererr("out of memory reading the transport request");
    }
    FIELDS = grown;
    FIELDS[NFIELDS].name = head;
    FIELDS[NFIELDS].value = whole.data + at;
    FIELDS[NFIELDS].len = (size_t)len;
    NFIELDS++;

    at += (size_t)len;
    /* Skip the newline that terminates the payload. */
    if (at < whole.len && '\n' == whole.data[at]) {
      at++;
    }
  }

  /* Every value is NUL-terminated for the string fields; the payload
   * fields are used with their explicit length. */
  for (at = 0; at < NFIELDS; at++) {
    FIELDS[at].value[FIELDS[at].len] = '\0';
  }
}

/* ---------------------------------------------------------- the clock */

static long nowms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (long)tv.tv_sec * 1000L + (long)(tv.tv_usec / 1000);
}

/* ------------------------------------------------------------ connect */

/*
 * One deadline across ALL resolved addresses, not one per address.
 * Giving each the full ten seconds makes the real bound ten seconds
 * times however many addresses the name cares to return - which is not a
 * bound at all when the name is the attacker's.
 */
static int dial(const char *host, const char *port, long deadline) {
  struct addrinfo hints;
  struct addrinfo *list = NULL;
  struct addrinfo *entry;
  int sock = -1;

  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  if (0 != getaddrinfo(host, port, &hints, &list)) {
    answererr("cannot resolve host");
  }

  for (entry = list; NULL != entry; entry = entry->ai_next) {
    int flags;
    int result;

    if (0 >= deadline - nowms()) {
      break;
    }

    sock = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
    if (0 > sock) {
      continue;
    }

    flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    result = connect(sock, entry->ai_addr, entry->ai_addrlen);

    if (0 != result && EINPROGRESS == errno) {
      struct pollfd waiting;
      long left = deadline - nowms();

      waiting.fd = sock;
      waiting.events = POLLOUT;
      waiting.revents = 0;

      if (0 < left && 0 < poll(&waiting, 1, (int)left)) {
        int soerr = 0;
        socklen_t soerrlen = sizeof soerr;
        if (0 == getsockopt(sock, SOL_SOCKET, SO_ERROR, &soerr, &soerrlen) &&
            0 == soerr) {
          result = 0;
        }
      }
    }

    if (0 == result) {
      fcntl(sock, F_SETFL, flags);
      freeaddrinfo(list);
      return sock;
    }

    close(sock);
    sock = -1;
  }

  freeaddrinfo(list);
  answererr("connection refused or timed out");
  return -1;
}

/* Is this host an IP literal rather than a DNS name? Hostname
 * verification and SNI both branch on the answer. */
static int isipliteral(const char *host) {
  unsigned char scratch[16];

  if (1 == inet_pton(AF_INET, host, scratch)) {
    return 1;
  }
  if (1 == inet_pton(AF_INET6, host, scratch)) {
    return 1;
  }
  return 0;
}

/* ------------------------------------------------------------- fetch */

static void dofetch(void) {
  const char *host = fieldof("host", "");
  const char *port = fieldof("port", "443");
  const char *body = fieldof("data", "");
  size_t bodylen = 0;
  long usetls = numberof("tls", 0);
  long timeout = numberof("timeout", 10000);
  long maxbody = numberof("maxbody", 8 * 1024 * 1024);
  long deadline = nowms() + timeout;
  int sock;
  buf answer;
  size_t at;
  SSL_CTX *ctx = NULL;
  SSL *ssl = NULL;

  {
    size_t index;
    for (index = 0; index < NFIELDS; index++) {
      if (0 == strcmp(FIELDS[index].name, "data")) {
        bodylen = FIELDS[index].len;
      }
    }
  }

  sock = dial(host, port, deadline);

  if (usetls) {
    const char *bundle = getenv("SEKRETO_CA_BUNDLE");
    X509_VERIFY_PARAM *param;
    X509 *peer;

    ctx = SSL_CTX_new(TLS_client_method());
    if (NULL == ctx) {
      answererr("cannot create a TLS context");
    }

    /* (1) Chain verification against the system trust store. The NULL
     * callback is what makes a verification error abort the handshake
     * rather than be reported and ignored. */
    if (1 != SSL_CTX_set_default_verify_paths(ctx)) {
      answersslerr("cannot load the system trust store");
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);

    /* (4) SEKRETO_CA_BUNDLE, ADDITIVE: the default roots are already
     * loaded above and stay loaded. A private CA is how most internal
     * Vault deployments are set up, so a wrong path weakens nothing - it
     * adds no roots and raises nothing. */
    if (NULL != bundle && '\0' != bundle[0]) {
      if (1 != SSL_CTX_load_verify_locations(ctx, bundle, NULL)) {
        ERR_clear_error();
      }
    }

    ssl = SSL_new(ctx);
    if (NULL == ssl) {
      answererr("cannot create a TLS connection");
    }

    param = SSL_get0_param(ssl);
    X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);

    /* (2) Hostname verification - a SEPARATE step from the chain, and a
     * different call for an IP literal. SSL_set1_host does DNS-name
     * matching and will NOT match an iPAddress SAN, so an address like
     * https://127.0.0.1:8304 needs set1_ip_asc or it is not checked at
     * all. */
    if (isipliteral(host)) {
      if (1 != X509_VERIFY_PARAM_set1_ip_asc(param, host)) {
        answererr("cannot pin the peer address");
      }
    } else {
      if (1 != SSL_set1_host(ssl, host)) {
        answererr("cannot pin the peer hostname");
      }
      /* (3) SNI, for a name only: RFC 6066 forbids an IP literal here,
       * and OpenSSL will send whatever it is handed. */
      SSL_set_tlsext_host_name(ssl, host);
    }

    SSL_set_fd(ssl, sock);

    if (1 != SSL_connect(ssl)) {
      answersslerr("TLS handshake failed");
    }

    /* Belt and braces. SSL_VERIFY_PEER already aborts on a bad chain, but
     * a build or a callback that did not is worse than no TLS, so the
     * result is read back explicitly. */
    if (X509_V_OK != SSL_get_verify_result(ssl)) {
      answererr("TLS certificate verification failed");
    }

    peer = SSL_get1_peer_certificate(ssl);
    if (NULL == peer) {
      answererr("TLS peer sent no certificate");
    }
    X509_free(peer);
  }

  /* Write the framed request. */
  at = 0;
  while (at < bodylen) {
    int wrote;
    if (0 >= deadline - nowms()) {
      answererr("timed out sending the request");
    }
    if (usetls) {
      wrote = SSL_write(ssl, body + at, (int)(bodylen - at));
    } else {
      wrote = (int)write(sock, body + at, bodylen - at);
    }
    if (0 >= wrote) {
      if (!usetls && EINTR == errno) {
        continue;
      }
      answererr("connection lost while sending the request");
    }
    at += (size_t)wrote;
  }

  if (!usetls) {
    shutdown(sock, SHUT_WR);
  }

  /* Read to EOF. The request always carries `Connection: close`, so the
   * server closing is the end of the body. One byte over the cap is
   * enough to know it was exceeded; the Lua side decides what that
   * means. */
  bufinit(&answer);

  for (;;) {
    char chunk[65536];
    int got;
    long left = deadline - nowms();
    struct pollfd waiting;

    if (0 >= left) {
      answererr("timed out reading the response");
    }

    if (!usetls || 0 == SSL_pending(ssl)) {
      waiting.fd = sock;
      waiting.events = POLLIN;
      waiting.revents = 0;
      if (0 >= poll(&waiting, 1, (int)left)) {
        answererr("timed out reading the response");
      }
    }

    if (usetls) {
      got = SSL_read(ssl, chunk, sizeof chunk);
      if (0 >= got) {
        int why = SSL_get_error(ssl, got);
        if (SSL_ERROR_WANT_READ == why || SSL_ERROR_WANT_WRITE == why) {
          continue;
        }
        break;
      }
    } else {
      got = (int)read(sock, chunk, sizeof chunk);
      if (0 > got && EINTR == errno) {
        continue;
      }
      if (0 >= got) {
        break;
      }
    }

    if (!bufput(&answer, chunk, (size_t)got)) {
      answererr("out of memory reading the response");
    }

    if ((long)answer.len > maxbody) {
      break;
    }
  }

  if (usetls) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
  }
  close(sock);

  answerok(answer.data ? answer.data : "", answer.len);
  buffree(&answer);
}

/* -------------------------------------------------------------- exec */

/*
 * A child, with an argv ARRAY and no shell anywhere. The two streams are
 * drained CONCURRENTLY through one poll: reading stdout to EOF and only
 * then reading stderr deadlocks permanently the moment the child writes
 * more than one pipe buffer (64 KiB) to stderr, and secretspec's
 * box-drawn diagnostics reach that size easily.
 *
 * The child's stdin is /dev/null rather than a pipe nobody writes to, so
 * a CLI that reads it - one prompting for a passphrase when its
 * environment variable is absent - sees EOF and gives up instead of
 * waiting forever.
 */
static void doexec(void) {
  char **argv;
  size_t argc = 0;
  size_t index;
  int outpipe[2];
  int errpipe[2];
  int failpipe[2];
  char failure[256];
  ssize_t failed;
  pid_t child;
  buf out;
  buf why;
  int status = 0;
  int alive = 2;
  char head[128];
  int head_n;

  for (index = 0; index < NFIELDS; index++) {
    if (0 == strcmp(FIELDS[index].name, "arg")) {
      argc++;
    }
  }

  if (0 == argc) {
    answererr("no command given");
  }

  argv = calloc(argc + 1, sizeof(char *));
  if (NULL == argv) {
    answererr("out of memory");
  }

  argc = 0;
  for (index = 0; index < NFIELDS; index++) {
    if (0 == strcmp(FIELDS[index].name, "arg")) {
      argv[argc++] = FIELDS[index].value;
    }
  }

  /* The child inherits THIS process's environment, which is the Lua
   * process's environment, plus whatever `setenv` fields the caller sent.
   * Lua cannot enumerate its own environment - `os.getenv` reads one name
   * - so a caller-built environment would silently drop every variable
   * the port did not think to name, and a child like boru reads several
   * of its own. Inheriting and overriding is the only correct shape. */
  for (index = 0; index < NFIELDS; index++) {
    if (0 == strcmp(FIELDS[index].name, "setenv")) {
      putenv(FIELDS[index].value);
    }
  }

  if (0 != pipe(outpipe) || 0 != pipe(errpipe) || 0 != pipe(failpipe)) {
    answererr("cannot create a pipe");
  }

  /* The exec status pipe: close-on-exec, so a SUCCESSFUL exec closes it
   * with nothing written and the parent reads EOF. Anything that does
   * arrive is the reason exec failed. Guessing from an exit code cannot
   * do this - a real child is free to exit 127 too. */
  if (0 != fcntl(failpipe[1], F_SETFD, FD_CLOEXEC)) {
    answererr("cannot create a pipe");
  }

  child = fork();
  if (0 > child) {
    answererr("cannot fork");
  }

  if (0 == child) {
    int devnull = open("/dev/null", O_RDONLY);
    if (0 <= devnull) {
      dup2(devnull, 0);
      close(devnull);
    } else {
      close(0);
    }
    dup2(outpipe[1], 1);
    dup2(errpipe[1], 2);
    close(outpipe[0]);
    close(outpipe[1]);
    close(errpipe[0]);
    close(errpipe[1]);
    close(failpipe[0]);
    execvp(argv[0], argv);
    {
      /* execvpe only returns on failure. */
      const char *reason = strerror(errno);
      ssize_t ignored = write(failpipe[1], reason, strlen(reason));
      (void)ignored;
    }
    _exit(127);
  }

  close(outpipe[1]);
  close(errpipe[1]);
  close(failpipe[1]);

  failed = read(failpipe[0], failure, sizeof failure - 1);
  close(failpipe[0]);

  if (0 < failed) {
    failure[failed] = '\0';
    close(outpipe[0]);
    close(errpipe[0]);
    while (0 > waitpid(child, &status, 0)) {
      if (EINTR != errno) {
        break;
      }
    }
    {
      char message[512];
      snprintf(message, sizeof message, "EXECFAIL %s", failure);
      answererr(message);
    }
  }

  bufinit(&out);
  bufinit(&why);

  while (0 < alive) {
    struct pollfd waiting[2];
    int count = 0;
    int at;

    if (0 <= outpipe[0]) {
      waiting[count].fd = outpipe[0];
      waiting[count].events = POLLIN;
      waiting[count].revents = 0;
      count++;
    }
    if (0 <= errpipe[0]) {
      waiting[count].fd = errpipe[0];
      waiting[count].events = POLLIN;
      waiting[count].revents = 0;
      count++;
    }

    if (0 >= poll(waiting, (nfds_t)count, -1)) {
      if (EINTR == errno) {
        continue;
      }
      break;
    }

    for (at = 0; at < count; at++) {
      char chunk[65536];
      ssize_t got;

      if (0 == waiting[at].revents) {
        continue;
      }

      got = read(waiting[at].fd, chunk, sizeof chunk);
      if (0 < got) {
        if (!bufput(waiting[at].fd == outpipe[0] ? &out : &why, chunk, (size_t)got)) {
          answererr("out of memory reading the child");
        }
      } else if (0 > got && EINTR == errno) {
        continue;
      } else {
        close(waiting[at].fd);
        if (waiting[at].fd == outpipe[0]) {
          outpipe[0] = -1;
        } else {
          errpipe[0] = -1;
        }
        alive--;
      }
    }
  }

  while (0 > waitpid(child, &status, 0)) {
    if (EINTR != errno) {
      break;
    }
  }

  {
    int code = 0;
    if (WIFEXITED(status)) {
      code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
      code = 128 + WTERMSIG(status);
    }

    /* 127 is "could not be executed": the caller turns it into
     * `sekreto: cannot run <command>: ...` rather than a store error. */
    head_n = snprintf(head, sizeof head, "EXEC %d %zu %zu\n", code, out.len, why.len);
  }

  writeall(1, head, (size_t)head_n);
  writeall(1, out.data ? out.data : "", out.len);
  writeall(1, why.data ? why.data : "", why.len);

  buffree(&out);
  buffree(&why);
  exit(0);
}

int main(int argc, char **argv) {
  const char *mode;

  /* A child that exits while its pipe is still being written must not
   * take this process down with it. */
  signal(SIGPIPE, SIG_IGN);

  if (2 > argc) {
    answererr("no transport request given");
  }

  readrequest(argv[1]);

  mode = fieldof("mode", "fetch");

  if (0 == strcmp(mode, "exec")) {
    doexec();
  } else {
    dofetch();
  }

  return 0;
}
