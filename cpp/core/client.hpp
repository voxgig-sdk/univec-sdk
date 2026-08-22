// Univec SDK client. All transport and pipeline behaviour lives in the
// SdkClient base (core/types.hpp); this class binds the API-specific entity
// accessors and the test-mode constructor.

#ifndef SDK_CORE_CLIENT_HPP
#define SDK_CORE_CLIENT_HPP

#include <memory>

#include "../core/types.hpp"
#include "../entity/entities.hpp"

namespace sdk {

class UnivecSDK : public SdkClient {
public:
  explicit UnivecSDK(Value options = Value::undef()) : SdkClient(options) {}


  // Convert entity bound to this client.
  std::shared_ptr<ConvertEntity> convert(Value entopts = Value::undef()) {
    return std::make_shared<ConvertEntity>(this, entopts);
  }

  // Embed entity bound to this client.
  std::shared_ptr<EmbedEntity> embed(Value entopts = Value::undef()) {
    return std::make_shared<EmbedEntity>(this, entopts);
  }

  // EphemeralKey entity bound to this client.
  std::shared_ptr<EphemeralKeyEntity> ephemeral_key(Value entopts = Value::undef()) {
    return std::make_shared<EphemeralKeyEntity>(this, entopts);
  }

  // Model entity bound to this client.
  std::shared_ptr<ModelEntity> model(Value entopts = Value::undef()) {
    return std::make_shared<ModelEntity>(this, entopts);
  }


  // testSDK builds a client in test mode: the test feature is activated,
  // installing the in-memory mock transport (no network activity).
  static std::shared_ptr<UnivecSDK> testSDK() {
    return testSDK(Value::undef(), Value::undef());
  }

  static std::shared_ptr<UnivecSDK> testSDK(Value testopts, Value sdkopts) {
    auto sdk = std::make_shared<UnivecSDK>(SdkClient::testOptions(testopts, sdkopts));
    sdk->mode = "test";
    return sdk;
  }

  // Convenience no-arg constructor.
  static std::shared_ptr<UnivecSDK> create() {
    return std::make_shared<UnivecSDK>(Value::undef());
  }
};

using UnivecSDKPtr = std::shared_ptr<UnivecSDK>;

} // namespace sdk

#endif // SDK_CORE_CLIENT_HPP
