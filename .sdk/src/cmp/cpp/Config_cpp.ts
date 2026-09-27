import {
  Content,
  File,
  Folder,
  cmp,
  configDefinition,
  each,
  isAuthActive,
  resolveAuthIn,
  resolveAuthName,
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

  const { def: configDef } = configDefinition(model, target.name)

  const authIn = resolveAuthIn(model)
  const authName = resolveAuthName(model)

  if (isAuthActive(model) && null != configDef.options &&
    null != configDef.options.auth) {
    if ('header' !== authIn) {
      configDef.options.auth.in = authIn
    }
    if ('Authorization' !== authName) {
      configDef.options.auth.name = authName
    }
  }

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
