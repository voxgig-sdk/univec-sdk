// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/capability.hpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Capabilities (§11.1).
 *
 * A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF — because it is a
 * dependency on something that can do the job, and which instance is
 * doing it is exactly the configuration detail a plugin must not care
 * about. (§11.1 makes one narrow exception for a ref, and `host.cpp`
 * implements it; the ranking here is capabilities only.)
 *
 * But A BINDING IS TO AN INSTANCE, not to a capability, which is what
 * decides behaviour when the bound provider leaves while another match
 * remains. */

#ifndef VOXGIG_PLUGIN_CAPABILITY_HPP
#define VOXGIG_PLUGIN_CAPABILITY_HPP

#include "types.hpp"
#include "value.hpp"

namespace plugin {

/* Rank the matching providers best-first: highest `version`, then
 * LOWEST `priority` (default 0), then declaration position `pos`
 * ascending. `candidates` is a list of {ref, pos, provides}. */
V resolvecapability(const V& req, const V& candidates);

/* Does one provider satisfy one requirement? */
bool capmatches(const V& req, const V& prov);

/* PARTIAL MATCH, RECURSING INTO MAPS (§11.1): every leaf in the
 * requirement must be present and equal in the capability, keys not
 * mentioned are not checked. A LIST IS COMPARED LEAF-WISE AT THE SAME
 * LENGTH, not as a subset — "the first two of your three regions" is
 * not something `match` can say. */
bool capmatchvalue(const V& want, const V& got);

}  // namespace plugin

#endif
