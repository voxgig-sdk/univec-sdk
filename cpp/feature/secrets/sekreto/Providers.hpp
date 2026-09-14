// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/src/Providers.hpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// THE BUILT-IN PROVIDER KINDS - the same four in every port - and the
// address check every kind that dials one runs first.
//
// What makes a kind built in is that it needs nothing of the platform
// beyond reading a local file: no socket, no TLS, no crypto, no child
// process. These four are the floor every chain stands on, and a chain
// that reads secrets from options, the environment, a plaintext `.env` and
// a mounted secret directory works with no plugin loaded at all.
// Everything else - the vault clients, the cloud stores, the two CLIs, and
// SigV4 signing with them - is a voxgig/plugin definition and lives under
// `plugins/` (docs/design/plugin-providers.md).
//
// A port of typescript/src/provider/builtin.ts and
// typescript/src/provider/addr.ts, which are canonical.

#ifndef SEKRETO_PROVIDERS_HPP
#define SEKRETO_PROVIDERS_HPP

#include <memory>
#include <string>
#include <vector>

#include "Provider.hpp"

namespace sekreto {

/// Every kind this library ships, built in or as a plugin, so that an
/// unknown kind can be told from a plugin that was not passed in.
struct Kinds {
  std::vector<std::string> builtin;
  std::vector<std::string> plugin;
};

const Kinds& KINDS();

/// The four kinds a Sekreto can always build, as plugin definitions. Fresh
/// ones on every call: two Sekretos never share a definition.
std::vector<Definition> builtins();

// --------------------------------------------------------------- addresses

/// An address with any userinfo replaced by `[redacted]`, for messages.
std::string safeaddr(const std::string& addr);

/// Refuse to send a secret-bearing credential in the clear, and refuse an
/// address this library will not dial. Raises; answers nothing otherwise.
///
/// In the CORE even though only plugins dial: it is a rule about what may
/// be configured, it opens nothing itself, and a plugin that carried its
/// own copy would be a second opinion about what is safe.
void checkaddr(const std::string& addr);

// ----------------------------------------------------------- the helpers
//
// The helpers below are the shared bottom of every kind, built-in or
// plugin. They live in the CORE rather than beside the plugins that use
// them because each is inside the line that makes a kind built in - a
// local file, an environment variable, some string trimming - and a copy
// on each side of the boundary is two things to get wrong. It is the core
// lending downwards, never the core reaching up.

/// The first candidate that is non-empty, or the empty string.
std::string first(const std::string& one, const std::string& two);
std::string first(const std::string& one, const std::string& two, const std::string& three);

// -------------------------------------------------------------- file reads

enum class Readstate { Text, Absent, Failed };

/// The outcome of reading a file that may legitimately not be there.
struct Readout {
  Readstate state = Readstate::Absent;
  std::string text;
  std::string why;
};

/// Read a whole file.
///
/// Absence is a MISS and the chain carries on; anything else - permission
/// denied, an unreadable mount, a failing disk - is an ERROR, because
/// returning a miss there falls silently through to a weaker store.
///
/// Reading a local file is the line that makes a kind built in, so this
/// lives in the core and the plugins that also need one (a Kubernetes
/// service-account token, say) use this rather than carrying a second
/// copy. It is the core lending downwards, never the core reaching up.
Readout readfile(const std::string& path);

/// One environment variable, or "". An empty value is absence: every port
/// treats a variable exported blank as one never set.
std::string envvar(const std::string& name);

/// Strip one trailing slash - a store's base address, a secret directory.
std::string trimslash(const std::string& text);

/// Strip space, tab, CR and LF from both ends - and NOT `\f` or `\v`. The
/// `.env` parser needs those two as well and keeps its own wider trim
/// (`trimdotenv`, in Sekreto.cpp), because the spec pins what that produces;
/// reaching for this one there instead is a silent behaviour change.
std::string trimtext(const std::string& text);

/// Strip one trailing newline, which is a file's or a CLI's line ending
/// and never part of the secret.
std::string dropnewline(const std::string& text);

}  // namespace sekreto

#endif
