package JAVAPACKAGE.feature;

import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

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

    CompletableFuture<Object> fut =
        CompletableFuture.supplyAsync(() -> inner.fetch(ctx, url, fetchdef));

    try {
      return fut.get(deadline, TimeUnit.MILLISECONDS);
    }
    catch (TimeoutException e) {
      track(deadline);
      throw ctx.makeError("timeout",
          "Request exceeded timeout of " + deadline + "ms");
    }
    catch (java.util.concurrent.ExecutionException e) {
      Throwable cause = e.getCause();
      if (cause instanceof CompletionException && cause.getCause() != null) {
        cause = cause.getCause();
      }
      if (cause instanceof RuntimeException) {
        throw (RuntimeException) cause;
      }
      if (cause instanceof Error) {
        throw (Error) cause;
      }
      throw new RuntimeException(cause);
    }
    catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new RuntimeException(e);
    }
  }

  private void track(int deadline) {
    this.count++;
    this.ms = deadline;
  }
}
