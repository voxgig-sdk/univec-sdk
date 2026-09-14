// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (c/plugins/proc.c)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Running a child: the ONE object in this library that forks.
 *
 * The boru and secretspec providers read their secret from a CLI, which
 * is the interface those tools offer a program in another language. Two
 * things about doing that are not optional.
 *
 * BOTH STREAMS ARE DRAINED CONCURRENTLY. Reading stdout to EOF and only
 * then reading stderr deadlocks the moment the child writes more than one
 * pipe buffer (64 KiB on Linux) to stderr: the parent waits on stdout,
 * the child waits for room on stderr, and neither can move. Nothing here
 * sets a timeout, so that hang is permanent - get() simply never returns.
 * secretspec's diagnostics are box-drawn and reach that size easily. A
 * single poll() over both pipes is what avoids it.
 *
 * THE CHILD'S STDIN IS AT EOF, not an open pipe nobody writes to, so a
 * CLI that reads it - one prompting for a passphrase when its environment
 * variable is absent - gives up instead of waiting forever.
 *
 * argv is an array and never a shell string, and no secret is ever put on
 * a command line, where the process table publishes it.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "support.h"

static void drainpipe(sek_buf *into, int fd) {
  char chunk[4096];
  ssize_t got = read(fd, chunk, sizeof(chunk));

  if (0 < got) {
    sek_buf_addn(into, chunk, (size_t)got);
  }
}

sek_err sek_runcmd(sek_pool *pool, char *const argv[], const char *command, const char *envkey,
                   const char *envval, sek_ran *out) {
  int outpipe[2];
  int errpipe[2];
  int failpipe[2];
  pid_t child;
  sek_buf stdoutbuf;
  sek_buf stderrbuf;
  int status = 0;
  int childerrno = 0;

  out->out = NULL;
  out->why = NULL;
  out->status = 0;

  if (0 != pipe(outpipe)) {
    return sek_fmt(pool, "sekreto: cannot run %s: %s", command, strerror(errno));
  }
  if (0 != pipe(errpipe)) {
    close(outpipe[0]);
    close(outpipe[1]);
    return sek_fmt(pool, "sekreto: cannot run %s: %s", command, strerror(errno));
  }
  /* A close-on-exec pipe: the child writes its errno into it if exec
   * fails, and the successful exec closes it silently. Without it a
   * missing binary is indistinguishable from one that ran and exited. */
  if (0 != pipe(failpipe)) {
    close(outpipe[0]);
    close(outpipe[1]);
    close(errpipe[0]);
    close(errpipe[1]);
    return sek_fmt(pool, "sekreto: cannot run %s: %s", command, strerror(errno));
  }
  fcntl(failpipe[1], F_SETFD, FD_CLOEXEC);

  child = fork();

  if (0 > child) {
    close(outpipe[0]);
    close(outpipe[1]);
    close(errpipe[0]);
    close(errpipe[1]);
    close(failpipe[0]);
    close(failpipe[1]);
    return sek_fmt(pool, "sekreto: cannot run %s: %s", command, strerror(errno));
  }

  if (0 == child) {
    int devnull = open("/dev/null", O_RDONLY);
    int problem;

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

    if (NULL != envkey && NULL != envval) {
      setenv(envkey, envval, 1);
    }

    execvp(argv[0], argv);

    problem = errno;
    if (sizeof(problem) != (size_t)write(failpipe[1], &problem, sizeof(problem))) {
      /* Nothing left to do: the parent will see a closed pipe and an
       * exit status instead. */
    }
    _exit(127);
  }

  close(outpipe[1]);
  close(errpipe[1]);
  close(failpipe[1]);

  sek_buf_init(&stdoutbuf, pool);
  sek_buf_init(&stderrbuf, pool);

  {
    struct pollfd watch[2];
    int open_count = 2;

    watch[0].fd = outpipe[0];
    watch[1].fd = errpipe[0];
    watch[0].events = POLLIN;
    watch[1].events = POLLIN;

    while (0 < open_count) {
      int ready;

      watch[0].revents = 0;
      watch[1].revents = 0;

      ready = poll(watch, 2, -1);
      if (0 > ready) {
        if (EINTR == errno) {
          continue;
        }
        break;
      }

      {
        int index;
        for (index = 0; index < 2; index++) {
          if (0 > watch[index].fd) {
            continue;
          }

          if (0 != (watch[index].revents & POLLIN)) {
            drainpipe(0 == index ? &stdoutbuf : &stderrbuf, watch[index].fd);
          }

          if (0 != (watch[index].revents & (POLLHUP | POLLERR))) {
            /* Drain whatever is still buffered before letting go: a
             * short-lived child can write and exit between two polls. */
            for (;;) {
              char chunk[4096];
              ssize_t got = read(watch[index].fd, chunk, sizeof(chunk));
              if (0 >= got) {
                break;
              }
              sek_buf_addn(0 == index ? &stdoutbuf : &stderrbuf, chunk, (size_t)got);
            }
            close(watch[index].fd);
            watch[index].fd = -1;
            open_count--;
          }
        }
      }
    }

    if (0 <= watch[0].fd) {
      close(watch[0].fd);
    }
    if (0 <= watch[1].fd) {
      close(watch[1].fd);
    }
  }

  if (sizeof(childerrno) != (size_t)read(failpipe[0], &childerrno, sizeof(childerrno))) {
    childerrno = 0;
  }
  close(failpipe[0]);

  while (0 > waitpid(child, &status, 0)) {
    if (EINTR != errno) {
      break;
    }
  }

  if (0 != childerrno) {
    return sek_fmt(pool, "sekreto: cannot run %s: %s", command, strerror(childerrno));
  }

  out->out = stdoutbuf.data;

  /* stderr trimmed, because the miss/failure decision is made on its
   * text and a trailing newline is not part of what a tool said. */
  {
    size_t start = 0;
    size_t end = stderrbuf.len;
    while (start < end && (' ' == stderrbuf.data[start] || '\n' == stderrbuf.data[start] ||
                           '\r' == stderrbuf.data[start] || '\t' == stderrbuf.data[start])) {
      start++;
    }
    while (end > start && (' ' == stderrbuf.data[end - 1] || '\n' == stderrbuf.data[end - 1] ||
                           '\r' == stderrbuf.data[end - 1] || '\t' == stderrbuf.data[end - 1])) {
      end--;
    }
    out->why = sek_strndup(pool, stderrbuf.data + start, end - start);
  }

  out->status = WIFEXITED(status) ? WEXITSTATUS(status) : 1;

  return NULL;
}
