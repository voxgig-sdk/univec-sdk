// Univec SDK — BaseFeature (no-op base; mirrors java BaseFeature).

#ifndef SDK_FEATURE_BASE_HPP
#define SDK_FEATURE_BASE_HPP

#include <string>

#include "../core/types.hpp"

namespace sdk {

class BaseFeature : public Feature {
public:
  std::string version = "0.0.1";
  std::string name = "base";
  bool active = true;

  // addOpts positions this feature when added via the client `extend`
  // option: "__before__"/"__after__"/"__replace__" name another feature.
  Value addOpts = Value::undef();

  BaseFeature() = default;
  BaseFeature(const std::string& name_, const std::string& version_, bool active_)
      : version(version_), name(name_), active(active_) {}

  Value addOptions() override { return addOpts; }
  std::string getVersion() override { return version; }
  std::string getName() override { return name; }
  bool getActive() override { return active; }
};

} // namespace sdk

#endif // SDK_FEATURE_BASE_HPP
