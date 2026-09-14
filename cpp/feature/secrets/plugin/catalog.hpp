// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/catalog.hpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The definition catalog (§10.1).
 *
 * A definition is registered once and may back many instances. Option
 * shapes are validated AT REGISTRATION, not when a document happens to
 * exercise a key — so a malformed shape fails once, and in the same
 * place everywhere (§9.4). `declare/shape` pins that timing. */

#ifndef VOXGIG_PLUGIN_CATALOG_HPP
#define VOXGIG_PLUGIN_CATALOG_HPP

#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "types.hpp"
#include "value.hpp"

namespace plugin {

class Inst;

/* A DEFINITION IS DATA WITH FUNCTIONS IN IT, not a class to extend. A
 * document could produce one, which is the property that makes a
 * catalog a data structure rather than a compile-time registry. */
using Lifecycle = std::function<void(Inst&)>;
using Reconfigure = std::function<void(Inst&, const V& now, const V& previous)>;

struct Definition {
  std::string name;
  V shape;
  Lifecycle define;
  Lifecycle activate;
  Lifecycle deactivate;
  Lifecycle close;
  Reconfigure reconfigure;
};

using DefinitionPtr = std::shared_ptr<Definition>;

class Catalog {
 public:
  void add(const DefinitionPtr& def);
  DefinitionPtr get(const std::string& name) const;
  bool has(const std::string& name) const;
  V names() const;

 private:
  std::vector<std::pair<std::string, DefinitionPtr>> defs_;
};

using CatalogPtr = std::shared_ptr<Catalog>;

CatalogPtr makecatalog();

/* The callback for a phase, by the name the log and the corpus use. */
const Lifecycle* definitioncallback(const DefinitionPtr& d,
                                    const std::string& at);

}  // namespace plugin

#endif
