package JAVAPACKAGE.feature;

import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Utility;

// Client-side rate limiting via a token bucket. Each request consumes a
// token; when the bucket is empty the request waits until the bucket
// refills at `rate` tokens per second (with capacity `burst`, default:
// rate). This keeps the client under a server's published quota rather
// than discovering it via 429s. The clock (`now`) and the wait (`sleep`)
// are injectable so the accounting can be tested deterministically.
public class RatelimitFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;
  private double tokens = 0;
  private long last = 0;

  // Activity tracking (mirrors the ts client._ratelimit record).
  public int throttled = 0;
  public int waitMs = 0;

  public RatelimitFeature() {
    super("ratelimit", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);

    if (!this.active) {
      return;
    }

    double rate = FeatureOptions.foptNum(this.options, "rate", 5);
    double burst = FeatureOptions.foptNum(this.options, "burst", rate);
    this.tokens = burst;
    this.last = FeatureOptions.foptNow(this.options).getAsLong();

    final Utility.FetcherFn inner = ctx.utility.fetcher;

    ctx.utility.fetcher = (ctx2, url, fetchdef) -> {
      acquire();
      return inner.fetch(ctx2, url, fetchdef);
    };
  }

  private void acquire() {
    double rate = FeatureOptions.foptNum(this.options, "rate", 5);
    double burst = FeatureOptions.foptNum(this.options, "burst", rate);

    // Refill according to elapsed time.
    long now = FeatureOptions.foptNow(this.options).getAsLong();
    long elapsed = now - this.last;
    this.last = now;
    this.tokens = Math.min(burst, this.tokens + (elapsed / 1000.0) * rate);

    if (this.tokens >= 1) {
      this.tokens -= 1;
      return;
    }

    // Not enough tokens: wait for one to accrue, then consume it.
    double needed = 1 - this.tokens;
    int wait = (int) Math.ceil((needed / rate) * 1000);
    track(wait);
    if (wait > 0) {
      FeatureOptions.foptSleep(this.options).accept(wait);
    }
    this.last = FeatureOptions.foptNow(this.options).getAsLong();
    this.tokens = 0;
  }

  private void track(int wait) {
    this.throttled++;
    this.waitMs += wait;
  }
}
