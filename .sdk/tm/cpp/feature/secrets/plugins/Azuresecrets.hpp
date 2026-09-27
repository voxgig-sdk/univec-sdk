// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (cpp/plugins/Azuresecrets.hpp)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Azure Key Vault.
//
// A PLUGIN, not a built-in: this kind opens a socket, signs a request or
// spawns a process, so a chain that does not name it links none of that.
// The calling project includes this header and passes what it declares to
// the Sekreto constructor (docs/design/plugin-providers.md).

#ifndef SEKRETO_PLUGINS_AZURESECRETS_HPP
#define SEKRETO_PLUGINS_AZURESECRETS_HPP

#include "../sekreto/Provider.hpp"

namespace sekreto {

/// The `azuresecrets` provider kind, as a voxgig/plugin definition.
Definition azuresecrets();

}  // namespace sekreto

#endif
