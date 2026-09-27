// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (cpp/src/graph.hpp)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Whole-graph resolution (§11.4) — a pure function of the registry that
 * answers which instances can be live, and for each blocked one THE
 * SPECIFIC requirement that is unmet, and why. See graph.cpp. */

#ifndef VOXGIG_PLUGIN_GRAPH_HPP
#define VOXGIG_PLUGIN_GRAPH_HPP

#include "types.hpp"
#include "value.hpp"

namespace plugin {

/* [{ref, pos, provides?, requires?}] -> {resolved: [ref], blocked: [...]} */
V resolvegraph(const V& nodes);

}  // namespace plugin

#endif
