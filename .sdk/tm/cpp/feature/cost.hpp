// Univec SDK — cost feature (mirrors ts src/feature/cost/CostFeature.ts).
// Cost tracking and spend budget. Uses BOTH seams, which is the point of the
// feature: money is spent per HTTP ATTEMPT (a retried call is charged again,
// because the upstream API charges it again), but it is owed by an OPERATION.
// So the transport wrap prices each attempt, and preDone attributes the
// running total to `<entity>.<op>` and to the caller (the per-call ctrl
// actor, the same actor the audit feature records).
//
// The price of an attempt comes from the first source that answers: a
// response header (`header` x `perUnit`), the rate table (`rates`, keyed
// `<entity>.<op>` / `<op>` / `*`), then the flat `unit`. A body figure
// (`path` x `perUnit`, e.g. "usage.total_tokens") is read at preDone instead,
// from the already-parsed result, and describes the whole call, so it
// REPLACES the per-attempt estimate rather than adding to it.
//
// `budget` caps total spend. With `onBudget: "deny"` a further operation is
// refused at prePoint, before an endpoint is resolved and before anything
// reaches the network.
//
// ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
// cache is charged for money that was never spent. The default (map) order
// puts cache innermost and cost outside it, so activate them in list form
// with cost first.

#ifndef SDK_FEATURE_COST_HPP
#define SDK_FEATURE_COST_HPP

#include <exception>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class CostFeature : public BaseFeature {
public:
  struct CostBucket {
    int calls = 0;
    double amount = 0.0;
  };

  struct CostTotal {
    int calls = 0;
    int attempts = 0;
    double amount = 0.0;
    double reported = 0.0;
    double estimated = 0.0;
  };

  struct CostBudget {
    double limit = 0.0;
    double spent = 0.0;
    double remaining = 0.0;
    bool exceeded = false;
  };

  SdkClient* client = nullptr;
  Value options = Value::undef();

  // Aggregates (mirrors the ts client._cost record).
  std::string currency = "USD";
  CostTotal total;
  std::map<std::string, CostBucket> ops;
  std::map<std::string, CostBucket> actors;
  CostBudget budget;
  Value last = Value::undef();

  CostFeature() : BaseFeature("cost", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);

    double limit = fopt::foptNum(options, "budget", 0.0);

    currency = fopt::foptStr(options, "currency", "USD");
    total = CostTotal();
    ops.clear();
    actors.clear();
    budget = CostBudget();
    budget.limit = limit;
    budget.remaining = limit;
    last = Value::undef();
    pending.clear();
    seq = 0;

    if (!active) return;

    auto inner = ctx->utility->fetcher;
    ctx->utility->fetcher = [this, inner](CtxPtr ctx2, const std::string& url,
                                          const Value& fetchdef) -> Value {
      return charge(ctx2, url, fetchdef, inner);
    };
  }

  // The budget gate. Runs before endpoint resolution, so a refused call costs
  // nothing at all.
  void prePoint(CtxPtr ctx) override {
    if (!active) return;

    // Mark the context as running through the pipeline, so charge knows a
    // preDone is coming and does not commit the spend itself.
    pending[ctx->id].piped = true;

    if (budget.limit <= 0.0 || total.amount < budget.limit) return;

    budget.exceeded = true;

    if (fopt::foptStr(options, "onBudget", "warn") != "deny") return;

    auto err = ctx->makeError("cost_budget",
                              "Cost budget of " + numstr(budget.limit) + " " + currency +
                                  " is spent (" + numstr(total.amount) + " " + currency +
                                  " used)");
    // Short-circuit endpoint resolution; makePoint surfaces this error.
    ctx->out.pointError = err;
  }

  // Attribute the operation's spend once the call is finished.
  void preDone(CtxPtr ctx) override {
    finish(ctx, true);
  }

  // A failed operation still spent the money. When the pipeline throws,
  // preDone never runs, so without this the attempts are counted and the spend
  // is not, and a budget could never see the cost of a failed call. Whichever
  // hook fires first consumes the pending entry, so it commits exactly once.
  void preUnexpected(CtxPtr ctx) override {
    finish(ctx, false);
  }

private:
  // Per-operation accumulator, keyed by ctx id (the same shape metrics uses
  // for its start markers).
  struct Pending {
    int attempts = 0;
    double amount = 0.0;
    double reported = 0.0;
    double estimated = 0.0;
    std::string source = "none";
    // Set by prePoint. Its absence means the call never entered the pipeline
    // (direct/graphql), so charge commits the spend itself.
    bool piped = false;
  };

  std::map<std::string, Pending> pending;
  int seq = 0;

  void finish(CtxPtr ctx, bool done) {
    if (!active) return;

    auto it = pending.find(ctx->id);
    if (it == pending.end()) return;
    Pending p = it->second;
    pending.erase(it);

    // A FAILED operation that made no attempt never reached the network:
    // prePoint creates the pending entry to mark the context as piped, and
    // then the budget gate refuses the call (rbac, or an unresolvable
    // endpoint, short-circuits just as early). Committing it would count a
    // call that never happened and file a zero-amount record as `last`.
    //
    // A SUCCEEDED operation that made no attempt is the opposite case: it was
    // served from the cache. That is a real call, and the fact that it cost
    // nothing is the whole point of ordering cost inside the cache.
    if (!done && 0 == p.attempts) return;

    std::string entity = "_";
    std::string opname = "_";
    if (ctx->op) {
      if (!ctx->op->entity.empty()) entity = ctx->op->entity;
      if (!ctx->op->name.empty()) opname = ctx->op->name;
    }

    commit(ctx, p, entity, opname);
  }

  // Commit one operation's spend: totals, budget, per-op and per-actor
  // attribution, and the record. Shared by finish and the raw-request path in
  // charge, which has no preDone to reach.
  void commit(CtxPtr ctx, const Pending& p, const std::string& entity,
              const std::string& opname) {
    double amount = p.amount;
    double reported = p.reported;
    double estimated = p.estimated;
    std::string source = p.source;

    // A body figure prices the whole call, so it replaces the per-attempt
    // estimate rather than adding to it, and being server-stated the whole
    // amount counts as reported.
    double body = 0.0;
    if (bodyAmount(ctx, body)) {
      amount = body;
      reported = body;
      estimated = 0.0;
      source = "body";
    }

    spend(amount, reported, estimated);

    std::string actor = "anonymous";
    std::string optActor = fopt::foptStr(options, "actor", "");
    if (!optActor.empty()) actor = optActor;
    if (ctx->ctrl && !ctx->ctrl->actor.empty()) actor = ctx->ctrl->actor;

    total.calls++;
    bump(ops, entity + "." + opname, amount);
    bump(actors, actor, amount);

    seq++;
    Value record = vmap();
    map_put(record, "seq", Value(seq));
    map_put(record, "entity", Value(entity));
    map_put(record, "op", Value(opname));
    map_put(record, "actor", Value(actor));
    map_put(record, "amount", Value(amount));
    map_put(record, "currency", Value(currency));
    map_put(record, "source", Value(source));
    map_put(record, "attempts", Value(p.attempts));
    last = record;

    Value sink = getp(options, "sink");
    if (sink.is_injector()) {
      vs::Injection inj(Value::undef(), Value::undef());
      sink.as_injector()(inj, vlist({record}), std::string(""), Value::undef());
    }
  }

  Value charge(CtxPtr ctx, const std::string& url, const Value& fetchdef,
               const std::function<Value(CtxPtr, const std::string&, const Value&)>& inner) {
    // A throwing transport still costs an attempt. Without this, a run of
    // connection-level failures under `retry` (which catches and tries again)
    // would be charged nothing at all, and an onBudget "deny" ceiling could
    // never stop it.
    Value res = Value::undef();
    bool threw = false;
    std::exception_ptr caught;
    try {
      res = inner(ctx, url, fetchdef);
    } catch (...) {
      threw = true;
      caught = std::current_exception();
    }

    std::string source = "none";
    double amount = price(ctx, res, source);

    // Accumulated here, committed once at preDone. Adding each attempt to the
    // running total and then subtracting it again when a body figure
    // supersedes it loses precision to catastrophic cancellation.
    //
    // Reported and estimated are kept apart per ATTEMPT: a 503 priced from the
    // rate table followed by a 200 carrying the cost header is part estimate,
    // part reported, and collapsing both into the final attempt's category
    // would corrupt the split.
    Pending& p = pending[ctx->id];
    p.attempts++;
    p.amount += amount;
    if ("header" == source || "body" == source) p.reported += amount;
    else p.estimated += amount;
    p.source = source;

    total.attempts++;

    // direct() and graphql() reach the transport without dispatching any
    // pipeline hooks, so there is no prePoint to gate on and no preDone to
    // commit. Their spend is committed here, or it would never be counted.
    if (!p.piped) {
      Pending copy = p;
      pending.erase(ctx->id);
      commit(ctx, copy, "_", "direct");
    }

    if (threw) {
      std::rethrow_exception(caught);
    }

    return res;
  }

  // Price one attempt: a reported header figure, else the rate table, else
  // the flat unit.
  double price(CtxPtr ctx, const Value& res, std::string& source) {
    std::string header = fopt::foptStr(options, "header", "");
    if (!header.empty()) {
      std::string raw = fopt::fresHeader(res, header);
      if (!raw.empty()) {
        try {
          double n = std::stod(raw);
          source = "header";
          return n * perUnit();
        } catch (...) {
          // Not a number: fall through to the rate table.
        }
      }
    }

    double rate = 0.0;
    if (rateFor(ctx, rate)) {
      source = "table";
      return rate;
    }

    double unit = fopt::foptNum(options, "unit", 0.0);
    if (unit != 0.0) {
      source = "unit";
      return unit;
    }

    source = "none";
    return 0.0;
  }

  // The rate table uses the same lookup grammar as rbac's rules:
  // `<entity>.<op>`, then `<op>`, then `*`.
  bool rateFor(CtxPtr ctx, double& out) {
    Value rates = fopt::foptMap(options, "rates");
    if (is_nullish(rates)) return false;

    std::string entity = "";
    if (ctx->entity != nullptr) entity = ctx->entity->getName();
    else if (ctx->op) entity = ctx->op->entity;
    std::string opname = ctx->op ? ctx->op->name : "";

    for (const std::string& key : {entity + "." + opname, opname, std::string("*")}) {
      Value v = getp(rates, key);
      if (v.is_number()) {
        out = v.as_double();
        return true;
      }
    }
    return false;
  }

  // A usage figure from the parsed result body, priced by perUnit. Read here,
  // not at the transport seam, because the body is one-shot.
  bool bodyAmount(CtxPtr ctx, double& out) {
    std::string path = fopt::foptStr(options, "path", "");
    if (path.empty() || !ctx->result) return false;

    Value body = ctx->result->body;
    if (is_nullish(body)) return false;

    Value v = Struct::getpath(body, splitDots(path));
    if (v.is_number()) {
      out = v.as_double() * perUnit();
      return true;
    }
    if (v.is_string()) {
      try {
        out = std::stod(v.as_string()) * perUnit();
        return true;
      } catch (...) {
        return false;
      }
    }
    return false;
  }

  void spend(double amount, double reported, double estimated) {
    total.amount += amount;
    total.reported += reported;
    total.estimated += estimated;

    budget.spent = total.amount;
    if (budget.limit > 0.0) {
      budget.remaining = budget.limit - total.amount;
      if (budget.remaining < 0.0) budget.remaining = 0.0;
      if (total.amount >= budget.limit) budget.exceeded = true;
    } else {
      budget.remaining = 0.0;
    }
  }

  void bump(std::map<std::string, CostBucket>& bucket, const std::string& key,
            double amount) {
    CostBucket& b = bucket[key];
    b.calls++;
    b.amount += amount;
  }

  double perUnit() { return fopt::foptNum(options, "perUnit", 0.0); }

  // Render a money amount without an exponent or trailing zeros.
  static std::string numstr(double n) {
    std::string s = std::to_string(n);
    std::size_t last = s.find_last_not_of('0');
    if (last != std::string::npos && s[last] == '.') last--;
    return s.substr(0, last + 1);
  }

  // The body figure is a dot path; Struct::getpath takes segments. (paging
  // carries its own copy for the same reason: feature source is trimmed per
  // project, so a shared helper would vanish with whichever feature owns it.)
  static std::vector<std::string> splitDots(const std::string& path) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : path) {
      if (c == '.') {
        if (!cur.empty()) out.push_back(cur);
        cur.clear();
      } else {
        cur.push_back(c);
      }
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_COST_HPP
