// Univec SDK — rbac feature (mirrors java feature/RbacFeature.java).
// Client-side permission enforcement. prePoint short-circuits a disallowed
// call with an rbac_denied error stored on ctx.out (surfaced by makePoint
// before any network activity).

#ifndef SDK_FEATURE_RBAC_HPP
#define SDK_FEATURE_RBAC_HPP

#include <map>
#include <string>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class RbacFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  std::map<std::string, bool> granted;

  int allowed = 0;
  int denied = 0;
  Value last = Value::undef();

  RbacFeature() : BaseFeature("rbac", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);

    granted.clear();
    for (const auto& p : fopt::foptStrList(options, "permissions")) {
      granted[p] = true;
    }
  }

  void prePoint(CtxPtr ctx) override {
    if (!active) return;

    std::string required;
    bool hasRequired = requiredPerm(ctx, required);
    if (!hasRequired) {
      if (fopt::foptBool(options, "deny", false)) {
        reject(ctx, "<default-deny>");
      }
      return;
    }

    if ((granted.count("*") && granted["*"]) ||
        (granted.count(required) && granted[required])) {
      track(ctx, required, true);
      return;
    }

    reject(ctx, required);
  }

private:
  bool requiredPerm(CtxPtr ctx, std::string& out) {
    Value rules = fopt::foptMap(options, "rules");
    if (!rules.is_map()) return false;

    std::string entity = "";
    if (ctx->entity != nullptr) entity = ctx->entity->getName();
    else if (ctx->op) entity = ctx->op->entity;
    std::string opname = "";
    if (ctx->op) opname = ctx->op->name;

    for (const std::string& key : {entity + "." + opname, opname, std::string("*")}) {
      Value r = getp(rules, key);
      if (r.is_string()) {
        out = r.as_string();
        return true;
      }
    }
    return false;
  }

  void reject(CtxPtr ctx, const std::string& required) {
    track(ctx, required, false);
    std::string opname = "?";
    if (ctx->op) opname = ctx->op->name;
    auto err = ctx->makeError("rbac_denied",
        "Permission \"" + required + "\" required for operation \"" + opname + "\"");
    // Short-circuit endpoint resolution; makePoint surfaces this error.
    ctx->out.pointError = err;
  }

  void track(CtxPtr ctx, const std::string& required, bool wasAllowed) {
    if (wasAllowed) allowed++;
    else denied++;
    std::string opname = "";
    if (ctx->op) opname = ctx->op->name;
    Value rec = vmap();
    map_put(rec, "required", Value(required));
    map_put(rec, "allowed", Value(wasAllowed));
    map_put(rec, "op", Value(opname));
    last = rec;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_RBAC_HPP
