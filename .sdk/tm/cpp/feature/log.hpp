// Univec SDK — log feature (mirrors java feature/LogFeature.java).
// Hook logging. The java donor uses java.util.logging; the C++ target has no
// such facility, so this emits the same "hook=… op=… spec=…" lines to
// std::cerr, gated by a level threshold, unless the `logger` option names a
// callable, which then receives [level, record] for every line instead.
// Active by default (like the java donor: the constructor sets active=true
// and init only overrides it when options.active is an explicit boolean).

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
      logger = getp(options, "logger");
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
  Value logger = Value::undef();

  // A log line leaves the pipeline, so it carries the cleaned record: the
  // spec after auth holds the credential, and a logger serialises whatever
  // it is handed.
  void loghook(const std::string& hook, CtxPtr ctx, std::string level) {
    if (!hasLogger) return;

    if (level.empty()) level = "info";

    // The per-call level (always "info" here) is emitted iff it clears the
    // configured threshold (mirrors Logger.info() vs Logger.setLevel()).
    int callLevel = 800;
    std::string tag = "INFO";
    if (level == "debug") { callLevel = 500; tag = "FINE"; }
    else if (level == "warn") { callLevel = 900; tag = "WARNING"; }
    else if (level == "error") { callLevel = 1000; tag = "SEVERE"; }

    if (callLevel < levelThreshold) return;

    Value record = vmap();
    map_put(record, "hook", Value(hook));
    if (ctx->op) map_put(record, "op", Value(ctx->op->name));
    if (ctx->spec) map_put(record, "spec", ctx->spec->toValue());
    map_put(record, "ctx", ctx->toValue());
    record = ctx->utility->clean(ctx, record);

    if (logger.is_injector()) {
      vs::Injection inj(Value::undef(), Value::undef());
      logger.as_injector()(inj, vlist({Value(level), record}), std::string(""), Value::undef());
      return;
    }

    std::string msg = "hook=" + hook;
    if (ctx->op) msg += " op=" + ctx->op->name;
    if (ctx->spec) {
      Value spec = getp(record, "spec");
      msg += " spec=" + as_str(getp(spec, "method")) + " " + as_str(getp(spec, "path"));
    }
    std::cerr << "UnivecSDK.log " << tag << ": " << msg << "\n";
  }
};

} // namespace sdk

#endif // SDK_FEATURE_LOG_HPP
