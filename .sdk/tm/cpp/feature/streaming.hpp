// Univec SDK — streaming feature (mirrors java feature/StreamingFeature.java).
// Streaming result support. For list-style operations it attaches a
// `result.stream` supplier yielding the items so callers can consume them
// incrementally. A `chunkSize` groups items into list batches when set; a
// `chunkDelay` (ms) paces delivery via the injectable `sleep`. Each stream()
// call reads the current resdata and produces a fresh sequence.

#ifndef SDK_FEATURE_STREAMING_HPP
#define SDK_FEATURE_STREAMING_HPP

#include <algorithm>
#include <cstddef>
#include <string>
#include <vector>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class StreamingFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();

  // Activity tracking (mirrors the ts client._streaming record).
  int opened = 0;

  StreamingFeature() : BaseFeature("streaming", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
  }

  void preResult(CtxPtr ctx) override {
    if (!active || !streamable(ctx)) return;
    ResultPtr result = ctx->result;
    if (!result) return;

    result->streaming = true;
    result->stream = [this, result]() -> std::vector<Value> {
      return iterate(result);
    };

    opened++;
  }

private:
  std::vector<Value> iterate(ResultPtr result) {
    int chunkDelay = fopt::foptInt(options, "chunkDelay", 0);
    int chunkSize = fopt::foptInt(options, "chunkSize", 0);
    auto sleep = fopt::foptSleep(options);

    // Read lazily at stream() call time so downstream result processing
    // is reflected.
    std::vector<Value> items;
    if (result->resdata.is_list()) {
      auto lst = result->resdata.as_list();
      items.assign(lst->begin(), lst->end());
    }

    std::vector<Value> out;
    std::size_t index = 0;
    while (index < items.size()) {
      if (chunkDelay > 0) sleep(chunkDelay);
      if (chunkSize > 0) {
        std::size_t end = std::min(index + (std::size_t) chunkSize, items.size());
        Value batch = vlist();
        for (std::size_t i = index; i < end; i++) batch.as_list()->push_back(items[i]);
        out.push_back(batch);
        index = end;
      } else {
        out.push_back(items[index++]);
      }
    }
    return out;
  }

  bool streamable(CtxPtr ctx) {
    std::string opname = "";
    if (ctx->op) opname = ctx->op->name;
    std::vector<std::string> ops = fopt::foptStrList(options, "ops");
    if (!fopt::foptList(options, "ops").is_list()) {
      ops = {"list"};
    }
    for (const auto& o : ops) {
      if (o == opname) return true;
    }
    return false;
  }
};

} // namespace sdk

#endif // SDK_FEATURE_STREAMING_HPP
