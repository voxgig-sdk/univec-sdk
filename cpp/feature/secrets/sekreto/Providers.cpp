// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/src/Providers.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Providers.hpp"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include <cstdlib>

#include "Sekreto.hpp"

namespace sekreto {

// -------------------------------------------------------- shared machinery

std::string first(const std::string& one, const std::string& two) {
  return one.empty() ? two : one;
}

std::string first(const std::string& one, const std::string& two, const std::string& three) {
  if (!one.empty()) return one;
  if (!two.empty()) return two;
  return three;
}

std::string envvar(const std::string& name) {
  const char* value = std::getenv(name.c_str());
  return (nullptr == value) ? "" : value;
}

std::string trimslash(const std::string& text) {
  if (!text.empty() && '/' == text[text.size() - 1]) return text.substr(0, text.size() - 1);
  return text;
}

std::string trimtext(const std::string& text) {
  size_t start = 0;
  size_t stop = text.size();

  while (start < stop && (' ' == text[start] || '\t' == text[start] || '\n' == text[start] ||
                          '\r' == text[start])) {
    start++;
  }
  while (stop > start && (' ' == text[stop - 1] || '\t' == text[stop - 1] ||
                          '\n' == text[stop - 1] || '\r' == text[stop - 1])) {
    stop--;
  }

  return text.substr(start, stop - start);
}

std::string dropnewline(const std::string& text) {
  if (!text.empty() && '\n' == text[text.size() - 1]) return text.substr(0, text.size() - 1);
  return text;
}

// --------------------------------------------------------------- addresses

std::string safeaddr(const std::string& addr) {
  size_t mark = addr.find("://");
  if (std::string::npos == mark) return addr;

  size_t from = mark + 3;
  size_t stop = addr.find_first_of("/?#", from);
  std::string authority =
      (std::string::npos == stop) ? addr.substr(from) : addr.substr(from, stop - from);

  size_t at = authority.rfind('@');
  if (std::string::npos == at) return addr;

  return addr.substr(0, from) + "[redacted]" + addr.substr(from + at);
}

void checkaddr(const std::string& addr) {
  std::string scheme;

  // Literal and case-sensitive: `HTTP://localhost` is refused rather than
  // normalised, because normalising is where parsers start to disagree.
  if (0 == addr.compare(0, 8, "https://")) {
    scheme = "https://";
  } else if (0 == addr.compare(0, 7, "http://")) {
    scheme = "http://";
  } else {
    throw SekretoError("sekreto: not an http(s) address: " + safeaddr(addr));
  }

  std::string rest = addr.substr(scheme.size());

  // The authority ends at `/`, `?` or `#` only - never at `\`. A client
  // that also breaks on backslash can then only ever see a SHORTER host
  // than this did, which is the invariant that makes this check
  // trustworthy: it is never more permissive than what will be dialled.
  size_t stop = rest.find_first_of("/?#");
  std::string authority = (std::string::npos == stop) ? rest : rest.substr(0, stop);

  // Userinfo is refused outright rather than parsed around, and on https
  // as well as http. At worst it is the attack this whole function exists
  // to stop: `http://localhost:8200@evil.example.com/` is a request to
  // evil.example.com that reads, to anything that splits the authority on
  // ':', as loopback.
  if (std::string::npos != authority.find('@')) {
    throw SekretoError("sekreto: refusing an address with embedded credentials: " +
                       safeaddr(addr));
  }

  // An opening bracket with no closing one is not an address at all.
  if (!authority.empty() && '[' == authority[0] &&
      std::string::npos == authority.find(']')) {
    throw SekretoError("sekreto: not a valid http(s) address: " + safeaddr(addr));
  }

  if ("https://" == scheme) return;

  // A bracketed IPv6 literal keeps its brackets. Splitting the authority
  // on the first colon yields '[', so `http://[::1]:8200` could never
  // match the allowlist below, and a legitimate local vault was refused.
  std::string host = authority;

  if (!authority.empty() && '[' == authority[0]) {
    size_t close = authority.find(']');
    if (std::string::npos != close) host = authority.substr(0, close + 1);
  } else {
    size_t colon = authority.find(':');
    if (std::string::npos != colon) host = authority.substr(0, colon);
  }

  host = asciilower(host);

  // Literal, and exactly these four. Nothing is normalised: `0177.0.0.1`,
  // `2130706433` and `[::ffff:127.0.0.1]` are all refused, because no two
  // URL parsers agree on what they mean.
  if ("localhost" != host && "127.0.0.1" != host && "::1" != host && "[::1]" != host) {
    throw SekretoError("sekreto: refusing to send a token in plaintext to " + safeaddr(addr) +
                       " (use https)");
  }
}

// -------------------------------------------------------------- file reads

Readout readfile(const std::string& path) {
  Readout out;

  int fd = ::open(path.c_str(), O_RDONLY);

  if (0 > fd) {
    if (ENOENT == errno || ENOTDIR == errno) {
      out.state = Readstate::Absent;
      return out;
    }
    out.state = Readstate::Failed;
    out.why = strerror(errno);
    return out;
  }

  std::string body;
  char buf[8192];

  while (true) {
    ssize_t got = ::read(fd, buf, sizeof(buf));

    if (0 == got) break;

    if (0 > got) {
      if (EINTR == errno) continue;
      out.state = Readstate::Failed;
      out.why = strerror(errno);
      ::close(fd);
      return out;
    }

    body.append(buf, static_cast<size_t>(got));
  }

  ::close(fd);

  out.state = Readstate::Text;
  out.text = body;
  return out;
}

// ---------------------------------------------------------------- built in

namespace {

/// Environment variables: `api.token` from `API_TOKEN`.
class EnvProvider : public Provider {
 public:
  explicit EnvProvider(const std::string& prefix) : prefix_(prefix) {}

  std::optional<std::string> lookup(const std::string& name) override {
    const char* value = std::getenv(envkey(name, prefix_).c_str());
    if (nullptr == value) return std::nullopt;

    return std::string(value);
  }

  std::string describe() const override {
    return prefix_.empty() ? "env" : "env:" + prefix_;
  }

 private:
  std::string prefix_;
};

/// A `.env` file, read once, keyed exactly like the environment.
///
/// Loaded LAZILY: a chain may hold a dotenv provider and never be asked
/// anything, and an eager constructor would read whatever `.env` happens
/// to sit in the working directory.
class DotenvProvider : public Provider {
 public:
  DotenvProvider(const std::string& file, const std::string& prefix)
      : file_(file), prefix_(prefix) {}

  std::optional<std::string> lookup(const std::string& name) override {
    load();
    return values_.get(envkey(name, prefix_));
  }

  std::string describe() const override { return "dotenv:" + file_; }

 private:
  void load() {
    if (loaded_) return;

    Readout got = readfile(file_);

    switch (got.state) {
      case Readstate::Text:
        values_ = parsedotenv(got.text);
        break;
      // An absent file - or an absent directory - means "no secrets here",
      // exactly like the file provider.
      case Readstate::Absent:
        values_ = Ordered();
        break;
      case Readstate::Failed:
        throw SekretoError("sekreto: dotenv provider cannot read " + file_ + ": " + got.why);
    }

    loaded_ = true;
  }

  std::string file_;
  std::string prefix_;
  Ordered values_;
  bool loaded_ = false;
};

/// Literal values, keyed like environment variables. The spec uses this to
/// test chain behaviour without touching the outside world.
class MemoryProvider : public Provider {
 public:
  MemoryProvider(const Ordered& values, const std::string& prefix)
      : values_(values), prefix_(prefix) {}

  std::optional<std::string> lookup(const std::string& name) override {
    // An absent key is a miss; the empty string is a HIT.
    return values_.get(envkey(name, prefix_));
  }

  std::string describe() const override {
    return prefix_.empty() ? "memory" : "memory:" + prefix_;
  }

 private:
  Ordered values_;
  std::string prefix_;
};

/// A directory of one-secret-per-file entries, keyed like the environment:
/// `api.token` reads `<dir>/API_TOKEN`.
///
/// This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
/// secret, and a systemd credentials directory, so those all work with no
/// further configuration. Read on EVERY lookup, never cached: a mounted
/// secret is rotated under a running process. One trailing newline is
/// stripped - tools that write these files disagree about it, and a
/// newline is never part of a secret on purpose.
class FileProvider : public Provider {
 public:
  FileProvider(const std::string& dir, const std::string& prefix)
      : dir_(dir), prefix_(prefix) {}

  std::optional<std::string> lookup(const std::string& name) override {
    std::string key = envkey(name, prefix_);
    std::string path = dir_.empty() ? key : trimslash(dir_) + "/" + key;

    Readout got = readfile(path);

    if (Readstate::Absent == got.state) return std::nullopt;

    if (Readstate::Failed == got.state) {
      throw SekretoError("sekreto: file provider cannot read " + path + ": " + got.why);
    }

    std::string body = got.text;

    if (2 <= body.size() && "\r\n" == body.substr(body.size() - 2)) {
      return body.substr(0, body.size() - 2);
    }
    if (!body.empty() && '\n' == body[body.size() - 1]) {
      return body.substr(0, body.size() - 1);
    }

    return body;
  }

  std::string describe() const override { return "file:" + dir_; }

 private:
  std::string dir_;
  std::string prefix_;
};

}  // namespace

// --------------------------------------------------- the four, as plugins

std::vector<Definition> builtins() {
  return {
      providerplugin("env",
                     [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
                       return std::make_shared<EnvProvider>(spec.prefix);
                     }),
      providerplugin("memory",
                     [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
                       return std::make_shared<MemoryProvider>(spec.values, spec.prefix);
                     }),
      providerplugin("dotenv",
                     [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
                       return std::make_shared<DotenvProvider>(first(spec.file, ".env"),
                                                               spec.prefix);
                     }),
      providerplugin("file",
                     [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
                       return std::make_shared<FileProvider>(spec.dir, spec.prefix);
                     }),
  };
}

const Kinds& KINDS() {
  static const Kinds one{
      {"env", "memory", "dotenv", "file"},
      {"hashicorp", "boru", "awssecrets", "awsparams", "gcpsecrets", "azuresecrets",
       "onepassword", "doppler", "infisical", "secretspec"},
  };
  return one;
}

}  // namespace sekreto
