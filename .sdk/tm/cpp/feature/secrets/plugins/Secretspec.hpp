// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Secretspec.hpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// SecretSpec, read through its own CLI.
//
// A PLUGIN, not a built-in: this kind opens a socket, signs a request or
// spawns a process, so a chain that does not name it links none of that.
// The calling project includes this header and passes what it declares to
// the Sekreto constructor (docs/design/plugin-providers.md).

#ifndef SEKRETO_PLUGINS_SECRETSPEC_HPP
#define SEKRETO_PLUGINS_SECRETSPEC_HPP

#include "../sekreto/Provider.hpp"

namespace sekreto {

/// The `secretspec` provider kind, as a voxgig/plugin definition.
Definition secretspec();

/// Does this SecretSpec failure mean "no such secret"? Matched on the
/// WHOLE phrase, key included.
bool secretspecmiss(const std::string& why, const std::string& key);

}  // namespace sekreto

#endif
