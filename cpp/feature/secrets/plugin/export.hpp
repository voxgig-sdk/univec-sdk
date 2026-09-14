// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/export.hpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Exports (§11). An instance publishes values for other plugins and for
 * the application. THE UNQUALIFIED ALIAS IS THE INTERESTING PART; see
 * export.cpp. */

#ifndef VOXGIG_PLUGIN_EXPORT_HPP
#define VOXGIG_PLUGIN_EXPORT_HPP

#include "types.hpp"
#include "value.hpp"

namespace plugin {

/* `retry$fast/client` or the alias `retry/client`, against a list of
 * {ref, key, value}. Answers nullptr for "no such export", which is not
 * an error — `export/missing` pins that, and is why the answer is a
 * nullptr rather than a null Value. */
V resolveexport(const V& spec, const V& exported);

}  // namespace plugin

#endif
