// Univec SDK — test feature: in-memory mock transport (mirrors java
// feature/TestFeature.java). Serves entity fixtures (options.entity) through
// the normal pipeline, and optionally simulates network conditions via the
// `net` block (latency / failures / outages) over the mock.

#ifndef SDK_FEATURE_TEST_HPP
#define SDK_FEATURE_TEST_HPP

#include <string>
#include <vector>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class TestFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();
  int netcalls = 0;

  TestFeature() : BaseFeature("test", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;

    Value entity = Helpers::toMapAny(getp(options, "entity"));
    client->mode = "test";

    // Ensure entity ids are correct (2-deep maps get id = their key).
    if (entity.is_map()) {
      Struct::walk(entity, [](const Value& key, const Value& val, const Value& parent,
                              const std::vector<std::string>& path) -> Value {
        if (path.size() == 2 && val.is_map() && key.is_string()) {
          map_put(val, "id", key);
        }
        return val;
      });
    }

    Value entities = entity.is_map() ? entity : vmap();

    std::function<Value(CtxPtr, const std::string&, const Value&)> testFetcher =
        [this, entities](CtxPtr fctx, const std::string& fullurl, const Value& fetchdef) -> Value {
      return this->serve(fctx, entities);
    };

    Value net = Helpers::toMapAny(getp(options, "net"));
    if (!net.is_map()) {
      ctx->utility->fetcher = testFetcher;
    } else {
      ctx->utility->fetcher = makeNetsim(net, testFetcher);
    }
  }

private:
  // THE MOCK HAS TO AGREE WITH THE MODEL. A point carrying
  // `transform.res: `body.item`` describes an API that answers {"item": {...}}
  // and the response transform unwraps that key on the way back. Returning the
  // bare payload means the transform unwraps a property that is not there and
  // the caller gets nothing. Mirrors the go/ts/lua/php mocks.
  Value envelope(CtxPtr ctx, const Value& data) {
    if (is_nullish(data) || !ctx) return data;
    Value tm = getp(ctx->point, "transform");
    Value restf = getp(tm, "res");
    if (!restf.is_string()) return data;
    std::string spec = restf.as_string();
    // Exactly `body.<key>`; a deeper path is not an envelope this mock can
    // synthesise, so it is left alone rather than guessed at.
    if (spec.size() < 8) return data;
    if (0 != spec.compare(0, 6, "`body.")) return data;
    if ('`' != spec[spec.size() - 1]) return data;
    std::string inner = spec.substr(6, spec.size() - 7);
    if (inner.empty() || std::string::npos != inner.find('.')) return data;
    Value wrapped = vmap();
    map_put(wrapped, inner, data);
    return wrapped;
  }

  Value respond(CtxPtr ctx, int status, const Value& data, const Value& extra) {
    Value out = vmap();
    map_put(out, "status", Value(status));
    map_put(out, "statusText", Value("OK"));
    map_put(out, "json", json_thunk(envelope(ctx, data)));
    map_put(out, "body", Value("not-used"));
    if (extra.is_map()) {
      for (const auto& kv : *extra.as_map()) map_put(out, kv.first, kv.second);
    }
    return out;
  }

  Value extra1(const std::string& key, const Value& val) {
    Value out = vmap();
    map_put(out, key, val);
    return out;
  }

  Value resolveMatch(CtxPtr ctx, const Value& explicitMatch) {
    if (explicitMatch.is_map() && !explicitMatch.as_map()->empty()) {
      return explicitMatch;
    }
    for (const Value& src : {ctx->match, ctx->data}) {
      if (!src.is_map()) continue;
      Value v = getp(src, "id", Value(nullptr));
      if (!v.is_null() && !(v.is_string() && v.as_string() == "__UNDEFINED__")) {
        Value out = vmap();
        map_put(out, "id", v);
        return out;
      }
    }
    return vmap();
  }

  Value serve(CtxPtr ctx, const Value& entity) {
    OperationPtr op = ctx->op;
    Value entmap = Helpers::toMapAny(getp(entity, op->entity));
    if (!entmap.is_map()) entmap = vmap();

    if (op->name == "load") {
      Value args = buildArgs(ctx, op, resolveMatch(ctx, ctx->reqmatch));
      std::vector<Value> found = Struct::select(entmap, args);
      Value ent = found.empty() ? Value::undef() : found[0];
      if (is_nullish(ent)) return respond(ctx, 404, Value(nullptr), extra1("statusText", Value("Not found")));
      Struct::delprop(ent, Value("$KEY"));
      Value out = Struct::clone(ent);
      return respond(ctx, 200, out, Value::undef());
    } else if (op->name == "list") {
      Value args = buildArgs(ctx, op, ctx->reqmatch);
      std::vector<Value> found = Struct::select(entmap, args);
      Value outlist = vlist();
      for (auto& item : found) {
        Struct::delprop(item, Value("$KEY"));
        outlist.as_list()->push_back(item);
      }
      Value out = Struct::clone(outlist);
      return respond(ctx, 200, out, Value::undef());
    } else if (op->name == "update") {
      Value updateMatch = vmap();
      if (ctx->reqdata.is_map()) {
        if (map_contains(ctx->reqdata, "id")) {
          map_put(updateMatch, "id", getp(ctx->reqdata, "id"));
        }
        if (op->alias.is_map()) {
          Value aliasIdRaw = getp(op->alias, "id");
          if (aliasIdRaw.is_string()) {
            std::string aliasId = aliasIdRaw.as_string();
            if (map_contains(ctx->reqdata, aliasId)) {
              map_put(updateMatch, aliasId, getp(ctx->reqdata, aliasId));
            }
          }
        }
      }
      if (!updateMatch.is_map() || updateMatch.as_map()->empty()) {
        updateMatch = resolveMatch(ctx, vmap());
      }
      Value args = buildArgs(ctx, op, updateMatch);
      std::vector<Value> found = Struct::select(entmap, args);
      Value ent = found.empty() ? Value::undef() : found[0];
      if (is_nullish(ent) && entmap.is_map()) {
        for (const auto& kv : *entmap.as_map()) {
          if (kv.second.is_map()) { ent = kv.second; break; }
        }
      }
      if (is_nullish(ent)) return respond(ctx, 404, Value(nullptr), extra1("statusText", Value("Not found")));
      if (ent.is_map() && ctx->reqdata.is_map()) {
        for (const auto& kv : *ctx->reqdata.as_map()) map_put(ent, kv.first, kv.second);
      }
      Struct::delprop(ent, Value("$KEY"));
      Value out = Struct::clone(ent);
      return respond(ctx, 200, out, Value::undef());
    } else if (op->name == "remove") {
      Value args = buildArgs(ctx, op, resolveMatch(ctx, ctx->reqmatch));
      std::vector<Value> found = Struct::select(entmap, args);
      Value ent = found.empty() ? Value::undef() : found[0];
      if (ent.is_map()) {
        Value id = getp(ent, "id", Value(nullptr));
        Struct::delprop(entmap, id);
      }
      return respond(ctx, 200, Value(nullptr), Value::undef());
    } else if (op->name == "create") {
      buildArgs(ctx, op, ctx->reqdata);
      Value id = ctx->utility->param(ctx, Value("id"));
      if (is_nullish(id)) {
        // deterministic-ish 16-hex-digit id
        static unsigned long long s = 0x2545F4914F6CDD1DULL;
        auto nib = [&]() {
          s = s * 6364136223846793005ULL + 1442695040888963407ULL;
          return (unsigned)((s >> 48) & 0xffff);
        };
        char buf[20];
        std::snprintf(buf, sizeof(buf), "%04x%04x%04x%04x", nib(), nib(), nib(), nib());
        id = Value(std::string(buf));
      }
      Value ent = Struct::clone(ctx->reqdata);
      if (ent.is_map()) {
        map_put(ent, "id", id);
        if (id.is_string()) map_put(entmap, id.as_string(), ent);
        Struct::delprop(ent, Value("$KEY"));
        Value out = Struct::clone(ent);
        return respond(ctx, 200, out, Value::undef());
      }
      return respond(ctx, 200, ent, Value::undef());
    }

    return respond(ctx, 404, Value(nullptr), extra1("statusText", Value("Unknown operation")));
  }

  // ---- net simulation over the mock -----------------------------------

  std::function<Value(CtxPtr, const std::string&, const Value&)>
  makeNetsim(const Value& net,
             std::function<Value(CtxPtr, const std::string&, const Value&)> inner) {
    netcalls = 0;
    return [this, net, inner](CtxPtr ctx, const std::string& url, const Value& fetchdef) -> Value {
      netcalls++;
      int call = netcalls;

      if (fopt::foptBool(net, "offline", false)) {
        netSleep(net, pickLatency(net));
        throw ctx->makeError("netsim_offline",
            "Simulated network offline (URL was: \"" + url + "\")");
      }
      if (call <= fopt::foptInt(net, "errorTimes", 0)) {
        netSleep(net, pickLatency(net));
        throw ctx->makeError("netsim_conn", "Simulated connection error (call " + std::to_string(call) + ")");
      }
      if (call <= fopt::foptInt(net, "failTimes", 0)) {
        netSleep(net, pickLatency(net));
        int status = fopt::foptInt(net, "failStatus", 503);
        Value out = vmap();
        map_put(out, "status", Value(status));
        map_put(out, "statusText", Value("Simulated Failure"));
        map_put(out, "body", Value("not-used"));
        map_put(out, "json", json_thunk(Value(nullptr)));
        map_put(out, "headers", vmap());
        return out;
      }
      netSleep(net, pickLatency(net));
      return inner(ctx, url, fetchdef);
    };
  }

  int pickLatency(const Value& net) {
    Value l = getp(net, "latency");
    if (is_nullish(l)) return 0;
    if (l.is_map()) {
      int mn = fopt::foptInt(l, "min", 0);
      int mx = fopt::foptInt(l, "max", mn);
      if (mx <= mn) return mn;
      return mn + ((mx - mn) >> 1);
    }
    int fixed = fopt::foptInt(net, "latency", 0);
    return fixed < 0 ? 0 : fixed;
  }

  void netSleep(const Value& net, int ms) {
    if (ms <= 0) return;
    fopt::foptSleep(net)(ms);
  }

  Value buildArgs(CtxPtr ctx, OperationPtr op, const Value& args) {
    std::string opname = op->name;

    Value points = Struct::getpath(ctx->config,
        {"entity", ctx->entity == nullptr ? std::string("") : ctx->entity->getName(),
         "op", opname, "points"});
    Value point = Struct::getelem(points, -1);

    Value paramsPath = Struct::getpath(point, {"args", "params"});
    std::vector<Value> reqdParamsSel = Struct::select(paramsPath, vmap({{"reqd", Value(true)}}));
    Value reqdParams = vlist();
    for (auto& p : reqdParamsSel) reqdParams.as_list()->push_back(p);
    Value reqd = Struct::transform(reqdParams, vlist({Value("`$EACH`"), Value(""), Value("`$KEY.name`")}));

    Value qand = vlist();
    Value q = vmap({{"`$AND`", qand}});

    if (args.is_map()) {
      for (const auto& key : Struct::keysof(args)) {
        bool isId = (key == "id");
        std::vector<Value> selected = Struct::select(reqd, Value(key));
        Value selv = vlist();
        for (auto& s : selected) selv.as_list()->push_back(s);
        bool isReqd = !Struct::isempty(selv);

        if (isId || isReqd) {
          Value v = ctx->utility->param(ctx, Value(key));
          Value ka = getp(op->alias, key);

          Value qor = vlist({vmap({{key, v}})});
          if (ka.is_string()) {
            qor.as_list()->push_back(vmap({{ka.as_string(), v}}));
          }
          qand.as_list()->push_back(vmap({{"`$OR`", qor}}));
        }
      }
    }

    if (ctx->ctrl->explain.is_map()) {
      map_put(ctx->ctrl->explain, "test", vmap({{"query", q}}));
    }

    return q;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_TEST_HPP
