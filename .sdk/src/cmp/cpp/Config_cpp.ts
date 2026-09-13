import {
  Content,
  File,
  Folder,
  cmp,
  configDefinition,
  each,
  targetFeatures,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


import {
  cppConfigLiterals,
} from './utility_cpp'


// PLUGIN DEFINITIONS PER FEATURE (the cpp peer of Config_c's
// pluginDefinitions and Config_go's featurePlugins map).
//
// Upstream sekreto retired its self-registration registry for voxgig/plugin
// definitions: a provider kind the caller did not pass in
// `SekretoOptions::plugins` is unknown to that Sekreto. So the model's
// choice of plugin groups IS the SDK's provider vocabulary, and the
// generated code names each active group's factory (`def: cpp:` in
// model/feature/secrets.aon - `hashicorp`, the `Definition hashicorp()`
// each vendored kind header declares in namespace sekreto) and nothing
// else. A symbol named here whose file the plugin trim removed is an
// unresolved reference at link time - a loud failure, which is the right
// kind. The owning file is kept per symbol because the generated
// translation unit has to include that file's header.
//
// One entry per ACTIVE feature that declares a `plugin` map at all, read
// with `only_active: false` (pluginExcludesFor's subtlety: the feature
// object a component is handed has already been filtered, so a feature
// whose groups are all off would otherwise look like one with no plugin
// machinery, and its kinds.cpp - which the Makefile reads as the feature's
// WIRING - would not be emitted).
function pluginDefinitions(model: Model, target: any):
  Record<string, { syms: Record<string, string>, groups: number }> {
  const out: Record<string, { syms: Record<string, string>, groups: number }> = {}
  const feature = targetFeatures(model, target)

  each(feature, (f: any) => {
    const declared = getModelPath(model,
      `main.${KIT}.feature.${f.name}.plugin`,
      { required: false, only_active: false }) || {}
    if (0 === Object.keys(declared).length) return

    const syms: Record<string, string> = {}
    let groups = 0
    each(declared, (plugin: any) => {
      // Filter on `active` HERE rather than trusting the feature object to
      // arrive filtered (Config_go's note): getting this wrong names a
      // factory for a file the trim just deleted.
      if (true !== plugin.active) return
      const defs = plugin.def?.[target.name] || {}
      if (0 < Object.keys(defs).length) groups++
      for (const sym of Object.keys(defs)) syms[sym] = String(defs[sym])
    })

    out[f.name] = { syms, groups }
  })

  return out
}


// feature/<name>/kinds.cpp - GENERATED, one per plugin-bearing active
// feature, and the ONE translation unit this otherwise header-only target
// generates.
//
// It cannot live in core/config.hpp: that header is included by every test
// translation unit, and it must not name the vendored voxgig/plugin's
// `Definition` type - the same reason go hides its list behind []any and c
// behind void**. So config.hpp's accessor is type-erased
// (std::shared_ptr<void>), and this file, which may include the kind
// headers, produces the erased list. It sits one level ABOVE the vendored
// sekreto/, plugin/ and plugins/ directories on purpose: the vendoring
// guard fails any non-vendored file inside a vendor dir, and this one is
// generated.
//
// Beside it goes feature/<name>/kinds.mk, the feature's BUILD WIRING: a
// generated make fragment that tm/cpp/Makefile reads through
// `-include $(wildcard feature/*/kinds.mk)`. The Makefile itself names no
// feature (the `nothing left behind names a dropped feature` guard holds a
// trimmed template tree to that), so everything the payload needs from the
// build is stated here, from the model: this translation unit and the
// vendored cores to compile into libsdkfeature.a, the suite to build, and
// - only when a plugin group is active - the plugin layer with the OpenSSL
// it brings. A tree whose model never activated the feature has no
// fragment, compiles none of the payload and links libstdc++ alone. Both
// files are emitted for an active feature with NO active group as well -
// an [env, memory] chain still needs the sekreto core - with an empty
// definitions list and no plugin layer.
//
// For `secrets` it additionally carries `secrets_rawfetch`, the
// token-exchange transport of last resort (go's rawExchangeFetch). The cpp
// core ships no HTTP client (utility/pipeline.hpp fetcher: "provide
// options.system.fetch"), and the decision for this target - as for c - is
// to bundle one INSIDE the gated feature, compiled in only when a plugin
// group is active, so an SDK without secrets, or with a chain of built-ins,
// still ships zero external dependencies. DELIBERATE DIVERGENCE from c,
// which bundles libcurl: the cpp sekreto port exports its own HTTPS client
// (`sekreto::httprequest`, plugins/Httpjson.cpp over plugins/Tls.cpp), and
// it is already compiled and linked - OpenSSL and all - on exactly the
// condition this transport needs. Reusing it means one HTTP stack and one
// -l pair (-lssl -lcrypto) instead of two; kinds.mk links OpenSSL on the
// same condition (a plugin group active), so the two cannot disagree.
// With no group active the exchange still works through a caller-supplied
// options.system.fetch, which every live cpp request already lives under;
// only the fallback is missing, and it says so.
const FeaturePlugins = cmp(async function FeaturePlugins(props: any) {
  const ctx$ = props.ctx$
  const target = props.target
  const model: Model = ctx$.model

  const defs = pluginDefinitions(model, target)
  if (0 === Object.keys(defs).length) return

  Folder({ name: 'feature' }, () => {
    for (const fname of Object.keys(defs).sort()) {
      const { syms, groups } = defs[fname]
      const symnames = Object.keys(syms).sort()

      // The header each selected kind file declares its factory in,
      // relative to this file (feature/<fname>/): `feature/<fname>/
      // plugins/Hashicorp.cpp` -> `plugins/Hashicorp.hpp`. Deduplicated,
      // because aws declares two factories in one header.
      const headers = Array.from(new Set(symnames.map((sym) =>
        syms[sym]
          .replace(new RegExp('^feature/' + fname + '/'), '')
          .replace(/\.cpp$/, '.hpp')))).sort()

      Folder({ name: fname }, () => {
        // The build wiring (see above). Paths are SDK-root-relative, as the
        // Makefile's own globs are. kinds.cpp itself is listed: nothing
        // else in the tree is a .cpp the Makefile would otherwise compile.
        File({ name: 'kinds.mk' }, () => {
          Content(`# Generated beside kinds.cpp: what the \`${fname}\` feature needs from the
# build, read by the Makefile through \`-include $(wildcard feature/*/kinds.mk)\`.
# Without this file none of the feature's vendored payload is compiled or
# linked. Do not hand-edit - change the model and regenerate.

# The wiring translation unit, the vendored cores every chain needs (sekreto
# and the voxgig/plugin host it is built on), and the feature's gated suite.
FEATURE_SRCS += feature/${fname}/kinds.cpp \\
  $(wildcard feature/${fname}/sekreto/*.cpp feature/${fname}/plugin/*.cpp)
FEATURE_TEST_SRCS += $(wildcard test/feature/${fname}/*.cpp)
`)
          if (0 === groups) {
            Content(`
# No plugin group is active: the plugin layer (the kinds, the socket HTTPS
# client and its OpenSSL binding, the digests and the child-process
# launcher) is on disk but NOT compiled - plugins/Tls.cpp hard-includes
# <openssl/ssl.h> - and nothing beyond libstdc++ is linked. A chain of
# built-ins needs none of it.
`)
          }
          else {
            Content(`
# A plugin group is active: the selected kinds and the four shared helpers
# they call (the socket HTTPS client, its OpenSSL binding, the digests and
# the child-process launcher), with the one external library they bring -
# OpenSSL, for the vault kinds' TLS and for the token-exchange transport of
# last resort in kinds.cpp, which rides on the same vendored client.
FEATURE_SRCS += $(wildcard feature/${fname}/plugins/*.cpp)
FEATURE_LIBS += -lssl -lcrypto
`)
          }
        })

        File({ name: 'kinds.cpp' }, () => {
          Content(`// Generated: the plugin definitions the model selected for the \`${fname}\`
// feature's provider chain (the cpp peer of go's core.FeaturePlugins),
// read back by core/config.hpp's featurePlugins("${fname}") and by the
// feature itself through ${fname}_plugins().
//
// GENERATED beside kinds.mk, the build wiring tm/cpp/Makefile includes. Do
// not hand-edit - change the model's plugin groups and regenerate.
//
// The one non-header translation unit this SDK generates: it includes the
// header-only SDK (for the declarations feature/${fname}.hpp makes) and the
// vendored kind headers, which core/config.hpp must never name.

#include "../../core/sdk.hpp"

#include <memory>
#include <string>
#include <utility>
#include <vector>

${headers.map((h) => `#include "${h}"
`).join('')}
namespace sdk {

${0 === symnames.length ?
`// No plugin group is active: the chain can name the four built-in kinds
// (env, memory, dotenv, file) and a custom provider, and nothing else.
std::vector<std::shared_ptr<void>> ${fname}_plugins() {
  return {};
}
` :
`// One factory call per selected kind, type-erased for config.hpp (the
// feature casts each back to plugin::DefinitionPtr).
std::vector<std::shared_ptr<void>> ${fname}_plugins() {
  return {
${symnames.map((sym) => `    std::static_pointer_cast<void>(sekreto::${sym}()),
`).join('')}  };
}
`}`)

          if ('secrets' !== fname) {
            Content(`
} // namespace sdk
`)
            return
          }

          if (0 === groups) {
            Content(`
// THE EXCHANGE TRANSPORT OF LAST RESORT, when no plugin group is active:
// there is none. The cpp core ships no HTTP client, and the vendored HTTPS
// client (plugins/Httpjson.cpp, OpenSSL) is compiled with the plugin
// groups only (see kinds.mk beside this file), so a token purchase needs
// options.system.fetch - the seam every live cpp request already uses.
// Reached only by an exchange whose caller supplied no transport; a chain
// that resolves a static credential never comes here.
SecretsRawResponse secrets_rawfetch(
    const std::string& method, const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& headers,
    const std::string& body) {
  (void)method; (void)headers; (void)body;
  SecretsRawResponse out;
  out.ok = false;
  out.err = "secrets: the token exchange has no HTTP transport: this SDK selected "
    "no secrets plugin group, so the vendored HTTPS client is not compiled; "
    "supply options.system.fetch or activate a plugin group (URL was: \\"" +
    url + "\\")";
  return out;
}

} // namespace sdk
`)
            return
          }

          Content(`
// THE EXCHANGE TRANSPORT OF LAST RESORT (go's rawExchangeFetch): the
// vendored sekreto HTTPS client, answering the status and raw body the
// feature turns into the transport-shaped map the system.fetch seam
// promises. It exists so an exchange works with ordinary SDK options -
// requiring a custom transport for the COMMON case would refuse every
// live token purchase before a request was made. Deliberately NOT the SDK
// transport: that is what the secrets feature wraps, and sending the
// token request back through it would recurse on the first expiry.
//
// \`sekreto::httprequest\` RETURNS a non-2xx status rather than raising (a
// 401 from a token endpoint is an answer), raises only on a transport
// failure, follows no redirect and consults no proxy - the properties a
// credential-bearing request wants. It is compiled because a plugin group
// is active in this model; kinds.mk links OpenSSL on exactly that
// condition. (c bundles libcurl here instead - see the note on
// FeaturePlugins in Config_cpp.ts for why cpp reuses the vendored client.)

} // namespace sdk

#include "plugins/Httpjson.hpp"

namespace sdk {

SecretsRawResponse secrets_rawfetch(
    const std::string& method, const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& headers,
    const std::string& body) {
  SecretsRawResponse out;
  try {
    sekreto::Ordered h;
    for (const auto& kv : headers) h.set(kv.first, kv.second);
    std::optional<std::string> reqbody;
    if (!body.empty()) reqbody = body;
    sekreto::Response res = sekreto::httprequest(method, url, h, reqbody);
    out.ok = true;
    out.status = res.status;
    out.body = res.body;
  } catch (const std::exception& e) {
    out.ok = false;
    out.err = std::string("secrets: token exchange transport failed: ") + e.what() +
      " (URL was: \\"" + url + "\\")";
  }
  return out;
}

} // namespace sdk
`)
        })
      })
    }
  })
})


// core/config.hpp: makeConfig() rebuilds the embedded API model by parsing a
// chunked JSON literal with the vendored struct parser; makeFeature(name) is
// the N-feature-safe by-name factory the client uses (mirrors Config_java /
// Config_go).
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  // The embedded config, built by the shared helper so this target's shapes
  // and identity fields stay in step with the ts reference by construction.
  // Passing target.name opts cpp into main.slug/version/target (the station
  // descriptor identity, ts/src/utility.ts configDefinition) - cpp has only
  // the data rep (one chunked JSON literal), so this is the whole #MainMeta
  // story for this target.
  const { def: configDef } = configDefinition(model, target.name)

  File({ name: 'config.' + target.ext }, () => {

    Content(`// Generated API configuration (mirrors Config_java / core/config.go).

#ifndef SDK_CORE_CONFIG_HPP
#define SDK_CORE_CONFIG_HPP

#include <memory>
#include <string>
#include <vector>

#include "../core/struct.hpp"
#include "../core/types.hpp"
#include "../feature/base.hpp"
`)

    each(feature, (f: any) => {
      if (f.name !== 'base') {
        Content(`#include "../feature/${f.name}.hpp"
`)
      }
    })

    Content(`
namespace sdk {

inline const char* config_json() {
  return
${cppConfigLiterals(configDef)};
}

inline Value makeConfig() { return vs::parse_json(config_json()); }

// SHARED CONFIG (sdkgen rung L2).
//
// The SDK reads the config on every request and never writes to it, so one
// instance is shared by every client rather than rebuilt per client - this is
// the difference between parsing the embedded JSON once and once per client.
//
// A function-local static in an inline function is one object across every
// translation unit, and its initialisation is thread-safe by the standard.
// Value holds shared_ptr nodes, so copying the returned Value shares the
// structure rather than duplicating it.
//
// The result is SHARED: treat it as read-only. Callers that need to mutate
// should use makeConfig, which always parses a fresh copy.
inline const Value& sharedConfig() {
  static const Value shared = makeConfig();
  return shared;
}

inline FeaturePtr makeFeature(const std::string& name) {
`)

    each(feature, (f: any) => {
      const fname = f.name.charAt(0).toUpperCase() + f.name.slice(1)
      if (f.name !== 'base') {
        Content(`  if (name == "${f.name}") return std::make_shared<${fname}Feature>();
`)
      }
    })

    Content(`  return std::make_shared<BaseFeature>();
}
`)

    // The plugin-definitions accessor, EMITTED UNCONDITIONALLY so a caller
    // can always ask, and EMPTY unless a plugin-bearing feature is active:
    // each such feature's list lives in its generated
    // feature/<name>/kinds.cpp (see FeaturePlugins above), which this
    // dispatches to by name, so this header never names the vendored
    // plugin's types - the list is type-erased (std::shared_ptr<void>; the
    // feature casts back to plugin::DefinitionPtr), the way go returns
    // []any and c void**. The per-feature function is an ordinary extern
    // declaration here and in the feature header alike; kinds.cpp defines
    // it, and the generated kinds.mk has the Makefile compile it.
    const plugged = Object.keys(pluginDefinitions(model, target)).sort()

    Content(`
// The plugin definitions the model selected per feature (type-erased; see
// feature/<name>/kinds.cpp). Empty for a feature with none, and for a
// model with no plugin-bearing feature active.
`)
    for (const fname of plugged) {
      Content(`std::vector<std::shared_ptr<void>> ${fname}_plugins();
`)
    }

    Content(`
inline std::vector<std::shared_ptr<void>> featurePlugins(const std::string& name) {
`)
    for (const fname of plugged) {
      Content(`  if (name == "${fname}") return ${fname}_plugins();
`)
    }
    Content(`  (void)name;
  return {};
}

} // namespace sdk

#endif // SDK_CORE_CONFIG_HPP
`)
  })
})


export {
  Config,
  FeaturePlugins,
  pluginDefinitions,
}
