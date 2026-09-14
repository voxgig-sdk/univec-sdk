// Generated: the plugin definitions the model selected for the `secrets`
// feature's provider chain (the cpp peer of go's core.FeaturePlugins),
// read back by core/config.hpp's featurePlugins("secrets") and by the
// feature itself through secrets_plugins().
//
// GENERATED beside kinds.mk, the build wiring tm/cpp/Makefile includes. Do
// not hand-edit - change the model's plugin groups and regenerate.
//
// The one non-header translation unit this SDK generates: it includes the
// header-only SDK (for the declarations feature/secrets.hpp makes) and the
// vendored kind headers, which core/config.hpp must never name.

#include "../../core/sdk.hpp"

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "plugins/Boru.hpp"
#include "plugins/Hashicorp.hpp"

namespace sdk {

// One factory call per selected kind, type-erased for config.hpp (the
// feature casts each back to plugin::DefinitionPtr).
std::vector<std::shared_ptr<void>> secrets_plugins() {
  return {
    std::static_pointer_cast<void>(sekreto::boru()),
    std::static_pointer_cast<void>(sekreto::hashicorp()),
  };
}

// THE EXCHANGE TRANSPORT OF LAST RESORT (go's rawExchangeFetch): the
// vendored sekreto HTTPS client, answering the status and raw body the
// feature turns into the transport-shaped map the system.fetch seam
// promises. It exists so an exchange works with ordinary SDK options -
// requiring a custom transport for the COMMON case would refuse every
// live token purchase before a request was made. Deliberately NOT the SDK
// transport: that is what the secrets feature wraps, and sending the
// token request back through it would recurse on the first expiry.
//
// `sekreto::httprequest` RETURNS a non-2xx status rather than raising (a
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
      " (URL was: \"" + url + "\")";
  }
  return out;
}

} // namespace sdk
