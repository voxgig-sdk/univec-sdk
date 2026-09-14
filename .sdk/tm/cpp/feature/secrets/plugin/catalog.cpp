// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/catalog.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The definition catalog (§10.1). */

#include "catalog.hpp"

#include "config.hpp"
#include "ref.hpp"

namespace plugin {

CatalogPtr makecatalog() { return std::make_shared<Catalog>(); }

void Catalog::add(const DefinitionPtr& def) {
  if (!def || !checkname(vstr(def->name))) {
    fail("plugin_definition_name",
         "invalid definition name: " + (def ? def->name : std::string()));
  }

  /* Validate the shape HERE. Deferring it to resolution time means a
   * malformed shape surfaces at a different moment in every host that
   * loads it, which is the divergence the stated domain exists to
   * prevent. */
  if (!isnull(def->shape)) checkshape(def->shape);

  for (auto& e : defs_) {
    if (e.first == def->name) { e.second = def; return; }
  }
  defs_.emplace_back(def->name, def);
}

DefinitionPtr Catalog::get(const std::string& name) const {
  for (const auto& e : defs_) {
    if (e.first == name) return e.second;
  }
  return nullptr;
}

bool Catalog::has(const std::string& name) const { return nullptr != get(name); }

V Catalog::names() const {
  V m = vmap();
  for (const auto& e : defs_) set(m, e.first, vbool(true));
  V out = vlist();
  for (const auto& k : sortedkeys(m)) push(out, vstr(k));
  return out;
}

const Lifecycle* definitioncallback(const DefinitionPtr& d,
                                    const std::string& at) {
  if (!d) return nullptr;
  if ("define" == at) return &d->define;
  if ("activate" == at) return &d->activate;
  if ("deactivate" == at) return &d->deactivate;
  if ("close" == at) return &d->close;
  return nullptr;
}

}  // namespace plugin
