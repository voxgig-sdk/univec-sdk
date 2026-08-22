// ProjectName SDK client. All transport and pipeline behaviour lives in the
// SdkClient base (core/types.hpp); this class binds the API-specific entity
// accessors and the test-mode constructor.

#ifndef SDK_CORE_CLIENT_HPP
#define SDK_CORE_CLIENT_HPP

#include <memory>

#include "../core/types.hpp"
#include "../entity/entities.hpp"

namespace sdk {

class ProjectNameSDK : public SdkClient {
public:
  explicit ProjectNameSDK(Value options = Value::undef()) : SdkClient(options) {}

  // <[SLOT]>

  // testSDK builds a client in test mode: the test feature is activated,
  // installing the in-memory mock transport (no network activity).
  static std::shared_ptr<ProjectNameSDK> testSDK() {
    return testSDK(Value::undef(), Value::undef());
  }

  static std::shared_ptr<ProjectNameSDK> testSDK(Value testopts, Value sdkopts) {
    auto sdk = std::make_shared<ProjectNameSDK>(SdkClient::testOptions(testopts, sdkopts));
    sdk->mode = "test";
    return sdk;
  }

  // Convenience no-arg constructor.
  static std::shared_ptr<ProjectNameSDK> create() {
    return std::make_shared<ProjectNameSDK>(Value::undef());
  }
};

using ProjectNameSDKPtr = std::shared_ptr<ProjectNameSDK>;

} // namespace sdk

#endif // SDK_CORE_CLIENT_HPP
