// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/export.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Exports (§11).
 *
 * THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client`
 * resolves to the UNTAGGED instance if one exists; if not, and exactly
 * one tagged instance exports that key, it resolves to that one; if two
 * do, it is `plugin_export_ambiguous` — deliberately diverging from
 * seneca's silent last-wins, because with multi-instance as a headline
 * feature an ambiguous alias is a defect waiting for production. */

#include "export.hpp"

#include <algorithm>

#include "ref.hpp"

namespace plugin {

V resolveexport(const V& spec, const V& exported) {
  const std::string s = isstr(spec) ? asstr(spec) : "";
  size_t cut = s.find('/');
  if (std::string::npos == cut) {
    fail("plugin_export_ambiguous", "export spec needs a key: " + s,
         details1("spec", vstr(s)));
  }
  const std::string head = s.substr(0, cut);
  const std::string key = s.substr(cut + 1);

  /* A fully qualified ref: exactly one answer or none.
   *
   * VALIDATING, not tolerant. The canonical calls `canonref(head)`,
   * which RAISES — so `retry$bad!/client` is `plugin_bad_tag` and
   * `2fa/client` is `plugin_bad_name`. Reading it with `tryref` turned
   * a configuration typo into an ordinary missing export, which is the
   * error the caller most needs to see, silently swallowed. */
  const std::string want = canonref(head);
  {
    for (size_t i = 0; i < len(exported); i++) {
      V e = at(exported, i);
      if (asstr(get(e, "ref")) == want && asstr(get(e, "key")) == key) {
        return get(e, "value");
      }
    }
  }

  /* An alias: the NAME, not a ref. Look at every instance of it. */
  std::vector<V> byname;
  for (size_t i = 0; i < len(exported); i++) {
    V e = at(exported, i);
    const std::string eref = asstr(get(e, "ref"));
    if (refname(eref) == head && asstr(get(e, "key")) == key) byname.push_back(e);
  }
  if (byname.empty()) return nullptr;

  /* The untagged instance wins outright when there is one. */
  for (const auto& e : byname) {
    if (std::string::npos == asstr(get(e, "ref")).find('$')) return get(e, "value");
  }

  if (1 == byname.size()) return get(byname[0], "value");

  std::vector<std::string> refs;
  for (const auto& e : byname) refs.push_back(asstr(get(e, "ref")));
  std::sort(refs.begin(), refs.end());

  V list = vlist();
  std::string names;
  for (size_t i = 0; i < refs.size(); i++) {
    if (0 < i) names += ", ";
    names += refs[i];
    push(list, vstr(refs[i]));
  }
  V d = vmap();
  set(d, "spec", vstr(s));
  set(d, "refs", list);
  fail("plugin_export_ambiguous",
       "alias " + s + " matches " + std::to_string(byname.size()) +
           " instances: " + names,
       d);
}

}  // namespace plugin
