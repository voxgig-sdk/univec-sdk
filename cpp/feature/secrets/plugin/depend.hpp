// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (cpp/src/depend.hpp)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Dependency cardinality, policy, and the restart graph (§11.3). Two
 * axes, both declared by the definition that has the requirement,
 * because only it knows what it can cope with. See depend.cpp. */

#ifndef VOXGIG_PLUGIN_DEPEND_HPP
#define VOXGIG_PLUGIN_DEPEND_HPP

#include "types.hpp"
#include "value.hpp"

namespace plugin {

V normrequire(const V& r);
V requirements(const V& options);

bool restartsonloss(const V& r);
bool gatesactivation(const V& r);
bool restartcausing(const V& r);

/* [{ref, provides:[name], requires:[req]}] -> the cycle, or nullptr. */
V dependencycycle(const V& nodes);
/* Raise on a cycle, naming it. Separate from the detector so the
 * detector stays pure and corpus-testable. */
void checkcycle(const V& nodes);

}  // namespace plugin

#endif
