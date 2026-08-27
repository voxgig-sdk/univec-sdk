// Univec SDK — log feature (mirrors java feature/LogFeature.java).
// Hook logging. The java donor uses java.util.logging; the C++ target has no
// such facility, so this emits the same "hook=… op=… spec=…" lines to
// std::cerr, gated by a level threshold. Active by default (like the java
// donor: the constructor sets active=true and init only overrides it when
// options.active is an explicit boolean).

#ifndef SDK_FEATURE_LOG_HPP
#define SDK_FEATURE_LOG_HPP

#include <iostream>
#include <string>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class LogFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  bool hasLogger = false;
  // java.util.logging levels: FINE=500, INFO=800, WARNING=900, SEVERE=1000.
  int levelThreshold = 800;

  LogFeature() : BaseFeature("log", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;

    Value a = getp(options, "active");
    if (a.is_bool()) active = a.as_bool();

    if (active) {
      hasLogger = true;
      Value lvl = getp(options, "level");
      if (lvl.is_string()) {
        std::string s = lvl.as_string();
        if (s == "debug") levelThreshold = 500;
        else if (s == "warn") levelThreshold = 900;
        else if (s == "error") levelThreshold = 1000;
        else levelThreshold = 800;
      } else {
        levelThreshold = 800;
      }
    }
  }

  void postConstruct(CtxPtr ctx) override { loghook("PostConstruct", ctx, ""); }
  void postConstructEntity(CtxPtr ctx) override { loghook("PostConstructEntity", ctx, ""); }
  void setData(CtxPtr ctx) override { loghook("SetData", ctx, ""); }
  void getData(CtxPtr ctx) override { loghook("GetData", ctx, ""); }
  void setMatch(CtxPtr ctx) override { loghook("SetMatch", ctx, ""); }
  void getMatch(CtxPtr ctx) override { loghook("GetMatch", ctx, ""); }
  void prePoint(CtxPtr ctx) override { loghook("PrePoint", ctx, ""); }
  void preSpec(CtxPtr ctx) override { loghook("PreSpec", ctx, ""); }
  void preRequest(CtxPtr ctx) override { loghook("PreRequest", ctx, ""); }
  void preResponse(CtxPtr ctx) override { loghook("PreResponse", ctx, ""); }
  void preResult(CtxPtr ctx) override { loghook("PreResult", ctx, ""); }

private:
  void loghook(const std::string& hook, CtxPtr ctx, std::string level) {
    if (!hasLogger) return;

    if (level.empty()) level = "info";

    std::string msg = "hook=" + hook;
    if (ctx->op) msg += " op=" + ctx->op->name;
    if (ctx->spec) msg += " spec=" + ctx->spec->method + " " + ctx->spec->path;

    // The per-call level (always "info" here) is emitted iff it clears the
    // configured threshold (mirrors Logger.info() vs Logger.setLevel()).
    int callLevel = 800;
    std::string tag = "INFO";
    if (level == "debug") { callLevel = 500; tag = "FINE"; }
    else if (level == "warn") { callLevel = 900; tag = "WARNING"; }
    else if (level == "error") { callLevel = 1000; tag = "SEVERE"; }

    if (callLevel >= levelThreshold) {
      std::cerr << "UnivecSDK.log " << tag << ": " << msg << "\n";
    }
  }
};

} // namespace sdk

#endif // SDK_FEATURE_LOG_HPP
