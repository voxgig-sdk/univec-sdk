package JAVAPACKAGE.feature;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Utility;

// Automatic retry of transient failures with exponential backoff and
// jitter. Wraps the active transport so a single operation call may make
// several HTTP attempts. A failure is retryable when the transport throws,
// returns nothing, or responds with a status in `statuses`
// (default: 408, 425, 429, 500, 502, 503, 504). An HTTP 429/503 with a
// `Retry-After` header overrides the computed backoff.
public class RetryFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;

  // Activity tracking (mirrors the ts client._retry record).
  public int attempts = 0;
  public List<Map<String, Object>> retries = new ArrayList<>();

  public RetryFeature() {
    super("retry", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);

    if (!this.active) {
      return;
    }

    final Utility.FetcherFn inner = ctx.utility.fetcher;

    ctx.utility.fetcher = (ctx2, url, fetchdef) ->
        withRetry(ctx2, url, fetchdef, inner);
  }

  private Object withRetry(Context ctx, String url, Map<String, Object> fetchdef,
      Utility.FetcherFn inner) {

    int max = FeatureOptions.foptInt(this.options, "retries", 2);
    int minDelay = FeatureOptions.foptInt(this.options, "minDelay", 50);
    int maxDelay = FeatureOptions.foptInt(this.options, "maxDelay", 2000);
    double factor = FeatureOptions.foptNum(this.options, "factor", 2);

    int attempt = 0;

    while (true) {
      Object res = null;
      RuntimeException err = null;
      try {
        res = inner.fetch(ctx, url, fetchdef);
      }
      catch (RuntimeException e) {
        err = e;
      }

      if (!retryable(res, err) || attempt >= max) {
        // Out of attempts (or not retryable): return the last
        // response/error as-is to preserve pipeline semantics.
        if (err != null) {
          throw err;
        }
        return res;
      }

      int wait = backoff(res, attempt, minDelay, maxDelay, factor);
      track(attempt + 1, res, err, wait);
      sleep(wait);
      attempt++;
    }
  }

  private boolean retryable(Object res, RuntimeException err) {
    if (err != null) {
      return true;
    }
    if (res == null) {
      return true;
    }
    int status = FeatureOptions.fresStatus(res);
    if (status < 0) {
      return false;
    }
    List<Object> statuses = FeatureOptions.foptList(this.options, "statuses");
    if (statuses == null) {
      statuses = List.of(408, 425, 429, 500, 502, 503, 504);
    }
    for (Object s : statuses) {
      if (s instanceof Number && ((Number) s).intValue() == status) {
        return true;
      }
    }
    return false;
  }

  private int backoff(Object res, int attempt, int minDelay, int maxDelay, double factor) {
    // Honour a server-provided Retry-After (seconds) when present.
    int ra = retryAfter(res);
    if (ra >= 0) {
      return Math.min(ra, maxDelay);
    }
    double base = minDelay * Math.pow(factor, attempt);
    int jitter = 0;
    if (FeatureOptions.foptBool(this.options, "jitter", true) && minDelay > 0) {
      jitter = ThreadLocalRandom.current().nextInt(minDelay);
    }
    int wait = (int) base + jitter;
    return Math.min(wait, maxDelay);
  }

  private int retryAfter(Object res) {
    String v = FeatureOptions.fresHeader(res, "retry-after");
    if ("".equals(v)) {
      return -1;
    }
    int seconds = FeatureOptions.fparseInt(v, -1);
    if (seconds < 0) {
      return -1;
    }
    return seconds * 1000;
  }

  private void sleep(int ms) {
    if (ms <= 0) {
      return;
    }
    FeatureOptions.foptSleep(this.options).accept(ms);
  }

  private void track(int attempt, Object res, RuntimeException err, int wait) {
    this.attempts++;

    Map<String, Object> entry = new LinkedHashMap<>();
    entry.put("attempt", attempt);
    entry.put("wait", wait);
    int status = FeatureOptions.fresStatus(res);
    if (status >= 0) {
      entry.put("status", status);
    }
    if (err != null) {
      entry.put("error", err.getMessage());
    }
    this.retries.add(entry);
  }
}
