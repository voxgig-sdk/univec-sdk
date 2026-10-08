package JAVAPACKAGE.feature;

import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.LongSupplier;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Utility;

// Per-request timeout. Wraps the active transport and races each attempt
// against a deadline; if the deadline wins, the request resolves to a
// `timeout` error instead of hanging. The inner transport is left to finish
// on its own thread (its result is discarded), matching how the ts feature
// lets the losing racer resolve unobserved.
public class TimeoutFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;

  // Activity tracking (mirrors the ts client._timeout record).
  public int count = 0;
  public int ms = 0;

  public TimeoutFeature() {
    super("timeout", "0.0.1", true);
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
        withTimeout(ctx2, url, fetchdef, inner);
  }

  private Object withTimeout(Context ctx, String url, Map<String, Object> fetchdef,
      Utility.FetcherFn inner) {

    int deadline = FeatureOptions.foptInt(this.options, "ms", 30000);
    if (deadline <= 0) {
      return inner.fetch(ctx, url, fetchdef);
    }

    // The deadline runs from here, not from the wait below: a caller paused
    // between the two would otherwise find a late response complete and take
    // it. The worker notes when it finished, so a response or a failure after
    // the deadline is a timeout however late the caller looks.
    final LongSupplier now = FeatureOptions.foptNow(this.options);
    final long start = now.getAsLong();
    final AtomicLong arrived = new AtomicLong(Long.MAX_VALUE);
    CompletableFuture<Object> fut = CompletableFuture.supplyAsync(() -> {
      try {
        return inner.fetch(ctx, url, fetchdef);
      }
      finally {
        arrived.set(now.getAsLong());
      }
    });

    try {
      long remaining = Math.max(0L, deadline - (now.getAsLong() - start));
      Object out;
      try {
        out = fut.get(remaining, TimeUnit.MILLISECONDS);
      }
      catch (java.util.concurrent.ExecutionException e) {
        if (deadline < arrived.get() - start) {
          throw timeout(ctx, deadline);
        }
        throw unwrap(e);
      }
      if (deadline < arrived.get() - start) {
        throw timeout(ctx, deadline);
      }
      return out;
    }
    catch (TimeoutException e) {
      throw timeout(ctx, deadline);
    }
    catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new RuntimeException(e);
    }
  }

  private static RuntimeException unwrap(java.util.concurrent.ExecutionException e) {
    Throwable cause = e.getCause();
    if (cause instanceof CompletionException && cause.getCause() != null) {
      cause = cause.getCause();
    }
    if (cause instanceof RuntimeException) {
      return (RuntimeException) cause;
    }
    if (cause instanceof Error) {
      throw (Error) cause;
    }
    return new RuntimeException(cause);
  }

  private RuntimeException timeout(Context ctx, int deadline) {
    track(deadline);
    return ctx.makeError("timeout", "Request exceeded timeout of " + deadline + "ms");
  }

  private void track(int deadline) {
    this.count++;
    this.ms = deadline;
  }
}
