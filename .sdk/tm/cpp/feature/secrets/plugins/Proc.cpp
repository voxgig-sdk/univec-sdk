// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Proc.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Proc.hpp"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdlib>

extern char** environ;

namespace sekreto {

namespace {

/// Where a command lives, searched along PATH, so that "this binary is not
/// installed" stays a `cannot run` error rather than arriving as a
/// non-zero exit the miss detection would then have to reason about.
bool findcommand(const std::string& command, const std::string& path, std::string& out) {
  auto runnable = [](const std::string& candidate) {
    return 0 == ::access(candidate.c_str(), X_OK);
  };

  if (std::string::npos != command.find('/')) {
    if (!runnable(command)) return false;
    out = command;
    return true;
  }

  size_t start = 0;

  while (start <= path.size()) {
    size_t at = path.find(':', start);
    std::string dir =
        (std::string::npos == at) ? path.substr(start) : path.substr(start, at - start);

    std::string candidate = dir.empty() ? command : dir + "/" + command;
    if (runnable(candidate)) {
      out = candidate;
      return true;
    }

    if (std::string::npos == at) break;
    start = at + 1;
  }

  return false;
}

}  // namespace

/// Run a child to completion and collect both its streams.
///
/// The two streams are drained CONCURRENTLY, by polling both pipes.
/// Reading stdout to EOF and only then reading stderr deadlocks the moment
/// the child writes more than one pipe buffer (64 KiB on Linux) to stderr:
/// the parent is blocked on stdout, the child is blocked waiting for room
/// on stderr, and neither can move. Nothing here sets a timeout, so that
/// hang is permanent - `get()` simply never returns. secretspec's
/// diagnostics are box-drawn and reach that size easily.
///
/// The child's stdin is the null device rather than a pipe nobody writes
/// to, so a CLI that reads it - one prompting for a passphrase when its
/// environment variable is absent - sees EOF and gives up instead of
/// waiting forever.
///
/// The argument list is passed as an array, never through a shell, and no
/// secret is ever put on a command line where the process table publishes
/// it.
Ran runcmd(const std::vector<std::string>& argv,
           const std::vector<std::string>& environment, const std::string& command) {
  std::string path;
  for (const std::string& entry : environment) {
    if (0 == entry.compare(0, 5, "PATH=")) path = entry.substr(5);
  }

  std::string binary;
  if (!findcommand(argv[0], path, binary)) {
    throw SekretoError("sekreto: cannot run " + command + ": no such file or directory");
  }

  int outpipe[2];
  int errpipe[2];

  if (0 != pipe(outpipe)) {
    throw SekretoError(std::string("sekreto: cannot run ") + command + ": " + strerror(errno));
  }
  if (0 != pipe(errpipe)) {
    ::close(outpipe[0]);
    ::close(outpipe[1]);
    throw SekretoError(std::string("sekreto: cannot run ") + command + ": " + strerror(errno));
  }

  std::vector<char*> args;
  for (const std::string& arg : argv) {
    args.push_back(const_cast<char*>(arg.c_str()));
  }
  args.push_back(nullptr);

  std::vector<char*> envp;
  for (const std::string& entry : environment) {
    envp.push_back(const_cast<char*>(entry.c_str()));
  }
  envp.push_back(nullptr);

  pid_t child = fork();

  if (0 > child) {
    ::close(outpipe[0]);
    ::close(outpipe[1]);
    ::close(errpipe[0]);
    ::close(errpipe[1]);
    throw SekretoError(std::string("sekreto: cannot run ") + command + ": " + strerror(errno));
  }

  if (0 == child) {
    int null = ::open("/dev/null", O_RDONLY);
    if (0 <= null) {
      dup2(null, STDIN_FILENO);
      ::close(null);
    }

    dup2(outpipe[1], STDOUT_FILENO);
    dup2(errpipe[1], STDERR_FILENO);

    ::close(outpipe[0]);
    ::close(outpipe[1]);
    ::close(errpipe[0]);
    ::close(errpipe[1]);

    execve(binary.c_str(), args.data(), envp.data());
    _exit(127);
  }

  ::close(outpipe[1]);
  ::close(errpipe[1]);

  Ran ran;
  std::string errtext;

  pollfd waiting[2];
  waiting[0].fd = outpipe[0];
  waiting[1].fd = errpipe[0];

  while (0 <= waiting[0].fd || 0 <= waiting[1].fd) {
    waiting[0].events = POLLIN;
    waiting[1].events = POLLIN;
    waiting[0].revents = 0;
    waiting[1].revents = 0;

    if (0 > poll(waiting, 2, -1)) {
      if (EINTR == errno) continue;
      break;
    }

    for (int side = 0; side < 2; side++) {
      if (0 > waiting[side].fd || 0 == waiting[side].revents) continue;

      char buf[4096];
      ssize_t got = ::read(waiting[side].fd, buf, sizeof(buf));

      if (0 < got) {
        if (0 == side) {
          ran.out.append(buf, static_cast<size_t>(got));
        } else {
          errtext.append(buf, static_cast<size_t>(got));
        }
        continue;
      }

      if (0 > got && EINTR == errno) continue;

      ::close(waiting[side].fd);
      waiting[side].fd = -1;
    }
  }

  if (0 <= waiting[0].fd) ::close(waiting[0].fd);
  if (0 <= waiting[1].fd) ::close(waiting[1].fd);

  int state = 0;
  while (0 > waitpid(child, &state, 0)) {
    if (EINTR != errno) break;
  }

  ran.status = WIFEXITED(state) ? WEXITSTATUS(state) : 1;
  ran.why = trimtext(errtext);

  return ran;
}

/// The process environment as `KEY=value` entries.
std::vector<std::string> processenv() {
  std::vector<std::string> out;

  for (char** step = environ; nullptr != *step; step++) {
    out.push_back(*step);
  }

  return out;
}

void setenvvar(std::vector<std::string>& environment, const std::string& key,
               const std::string& value) {
  std::string prefix = key + "=";

  for (std::string& entry : environment) {
    if (0 == entry.compare(0, prefix.size(), prefix)) {
      entry = prefix + value;
      return;
    }
  }

  environment.push_back(prefix + value);
}

}  // namespace sekreto
