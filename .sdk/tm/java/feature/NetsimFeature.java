package JAVAPACKAGE.feature;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Utility;

// Network behaviour simulation. Wraps the active transport (the live
// HttpClient fetch or the `test` feature's in-memory mock) and injects
// realistic network conditions so offline unit tests can exercise slowness,
// transient failures, rate limiting and outages deterministically.
//
// Every injection mode is counter-driven (per client instance) so tests
// are reproducible without mocking timers. `failRate` adds optional
// pseudo-random failures via a seeded LCG for coverage-style testing.
@SuppressWarnings({"unchecked"})
public class NetsimFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;
  private long seed = 1;

  // Activity tracking (mirrors the ts client._netsim record).
  public int calls = 0;
  public List<Map<String, Object>> applied = new ArrayList<>();

  public NetsimFeature() {
    super("netsim", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);

    this.seed = FeatureOptions.foptInt(this.options, "seed", 0);
    if (this.seed == 0) {
      this.seed = 1;
    }

    if (!this.active) {
      return;
    }

    final Utility.FetcherFn inner = ctx.utility.fetcher;

    ctx.utility.fetcher = (ctx2, url, fetchdef) ->
        simulate(ctx2, url, fetchdef, inner);
  }

  private Object simulate(Context ctx, String url, Map<String, Object> fetchdef,
      Utility.FetcherFn inner) {

    Map<String, Object> opts = this.options;
    this.calls++;
    int call = this.calls;

    // Record the simulated conditions for test/debug inspection.
    Map<String, Object> appliedRec = new LinkedHashMap<>();

    // Total outage: every call fails at the transport level.
    if (FeatureOptions.foptBool(opts, "offline", false)) {
      sleep(pickLatency());
      appliedRec.put("offline", true);
      track(ctx, appliedRec);
      throw ctx.makeError("netsim_offline",
          "Simulated network offline (URL was: \"" + url + "\")");
    }

    // Connection-level errors for the first N calls (e.g. ECONNRESET).
    if (call <= FeatureOptions.foptInt(opts, "errorTimes", 0)) {
      sleep(pickLatency());
      appliedRec.put("error", true);
      track(ctx, appliedRec);
      throw ctx.makeError("netsim_conn",
          "Simulated connection error (call " + call + ")");
    }

    // Rate-limit responses (HTTP 429 + Retry-After) for the first N calls.
    if (call <= FeatureOptions.foptInt(opts, "rateLimitTimes", 0)) {
      sleep(pickLatency());
      appliedRec.put("rateLimited", true);
      track(ctx, appliedRec);
      Map<String, Object> extra = new LinkedHashMap<>();
      extra.put("statusText", "Too Many Requests");
      Map<String, Object> headers = new LinkedHashMap<>();
      headers.put("retry-after",
          String.valueOf(FeatureOptions.foptInt(opts, "retryAfter", 0)));
      extra.put("headers", headers);
      return respond(429, null, extra);
    }

    // Retryable failure status for the first N calls, or every Nth call,
    // or pseudo-randomly at `failRate`.
    int failStatus = FeatureOptions.foptInt(opts, "failStatus", 503);
    int failEvery = FeatureOptions.foptInt(opts, "failEvery", 0);
    boolean failByCount = call <= FeatureOptions.foptInt(opts, "failTimes", 0);
    boolean failByEvery = failEvery > 0 && call % failEvery == 0;
    double failRate = FeatureOptions.foptNum(opts, "failRate", 0);
    boolean failByRate = failRate > 0 && rand() < failRate;
    if (failByCount || failByEvery || failByRate) {
      sleep(pickLatency());
      appliedRec.put("failStatus", failStatus);
      track(ctx, appliedRec);
      Map<String, Object> extra = new LinkedHashMap<>();
      extra.put("statusText", "Simulated Failure");
      return respond(failStatus, null, extra);
    }

    // Otherwise: apply latency then delegate to the real transport.
    int latency = pickLatency();
    appliedRec.put("latency", latency);
    track(ctx, appliedRec);
    sleep(latency);
    return inner.fetch(ctx, url, fetchdef);
  }

  // pickLatency yields ms: a fixed number, or a uniform sample from {min,max}.
  private int pickLatency() {
    Object l = this.options.get("latency");
    if (l == null) {
      return 0;
    }
    if (l instanceof Map) {
      Map<String, Object> lm = (Map<String, Object>) l;
      int min = FeatureOptions.foptInt(lm, "min", 0);
      int max = FeatureOptions.foptInt(lm, "max", min);
      if (max <= min) {
        return min;
      }
      return min + (int) (rand() * (max - min));
    }
    int fixed = FeatureOptions.foptInt(this.options, "latency", 0);
    return fixed < 0 ? 0 : fixed;
  }

  private void sleep(int ms) {
    if (ms <= 0) {
      return;
    }
    FeatureOptions.foptSleep(this.options).accept(ms);
  }

  // rand yields a deterministic 0..1 pseudo-random via a linear congruential
  // generator.
  private double rand() {
    this.seed = (this.seed * 1103515245L + 12345L) & 0x7fffffffL;
    return (double) this.seed / (double) 0x7fffffffL;
  }

  private void track(Context ctx, Map<String, Object> appliedRec) {
    this.applied.add(appliedRec);
    if (ctx.ctrl != null && ctx.ctrl.explain != null) {
      Map<String, Object> rec = new LinkedHashMap<>();
      rec.put("calls", this.calls);
      rec.put("applied", this.applied);
      ctx.ctrl.explain.put("netsim", rec);
    }
  }

  // respond builds a transport-shaped response (matching the test feature's
  // mock) that the result pipeline understands.
  private Map<String, Object> respond(int status, Object data, Map<String, Object> extra) {
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("status", status);
    out.put("statusText", "OK");
    out.put("json", (Supplier<Object>) () -> data);
    out.put("body", "not-used");
    out.put("headers", new LinkedHashMap<String, Object>());
    if (extra != null) {
      out.putAll(extra);
    }
    return out;
  }
}
