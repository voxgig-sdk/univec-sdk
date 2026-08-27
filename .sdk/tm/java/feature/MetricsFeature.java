package JAVAPACKAGE.feature;

import java.util.LinkedHashMap;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.SdkClient;

// Statistics capture. Records per-operation counters and latency for every
// call: totals plus a breakdown keyed by `<entity>.<op>`. Timing starts at
// endpoint resolution (PrePoint) and stops when the call returns (PreDone)
// or fails (PreUnexpected); each operation is recorded exactly once (the
// per-context start marker in ctx.out is consumed on record). The clock is
// injectable (`now`) for deterministic tests.
public class MetricsFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;

  // Aggregates (mirrors the ts client._metrics record).
  public MetricsBucket total = new MetricsBucket();
  public Map<String, MetricsBucket> ops = new LinkedHashMap<>();

  public static class MetricsBucket {
    public int count = 0;
    public int ok = 0;
    public int err = 0;
    public long totalMs = 0;
    public long maxMs = 0;
  }

  private static final String METRICS_START_KEY = "metrics_start";

  public MetricsFeature() {
    super("metrics", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);

    this.total = new MetricsBucket();
    this.ops = new LinkedHashMap<>();
  }

  @Override
  public void prePoint(Context ctx) {
    if (!this.active) {
      return;
    }
    ctx.out.put(METRICS_START_KEY, FeatureOptions.foptNow(this.options).getAsLong());
  }

  @Override
  public void preDone(Context ctx) {
    // Classify by the actual result: a 4xx/5xx that flows through still
    // reaches PreDone before the pipeline errors.
    record(ctx, ctx.result != null && ctx.result.ok && ctx.result.err == null);
  }

  @Override
  public void preUnexpected(Context ctx) {
    record(ctx, false);
  }

  private void record(Context ctx, boolean ok) {
    // Record once per operation: the missing start marker makes a second
    // call (PreDone followed by PreUnexpected on failure) a no-op.
    Object startRaw = ctx.out.get(METRICS_START_KEY);
    if (!(startRaw instanceof Long)) {
      return;
    }
    ctx.out.remove(METRICS_START_KEY);
    long start = (Long) startRaw;

    long dur = FeatureOptions.foptNow(this.options).getAsLong() - start;
    if (dur < 0) {
      dur = 0;
    }

    String entity = "_";
    String opname = "_";
    if (ctx.op != null) {
      entity = ctx.op.entity;
      opname = ctx.op.name;
    }
    String key = entity + "." + opname;

    MetricsBucket op = this.ops.get(key);
    if (op == null) {
      op = new MetricsBucket();
      this.ops.put(key, op);
    }

    bump(this.total, ok, dur);
    bump(op, ok, dur);
  }

  private void bump(MetricsBucket bucket, boolean ok, long dur) {
    bucket.count++;
    if (ok) {
      bucket.ok++;
    }
    else {
      bucket.err++;
    }
    bucket.totalMs += dur;
    if (dur > bucket.maxMs) {
      bucket.maxMs = dur;
    }
  }
}
