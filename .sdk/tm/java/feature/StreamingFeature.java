package JAVAPACKAGE.feature;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.function.IntConsumer;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.core.SdkClient;

// Streaming result support. For list-style operations it attaches a
// `result.stream` supplier yielding an iterator so callers can consume
// items incrementally instead of materialising the whole list at once. A
// `chunkSize` groups items into List<Object> batches when set; a
// `chunkDelay` (ms) paces delivery via the injectable `sleep` for offline
// tests. Each stream() call yields a fresh iterator.
@SuppressWarnings({"unchecked"})
public class StreamingFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;

  // Activity tracking (mirrors the ts client._streaming record).
  public int opened = 0;

  public StreamingFeature() {
    super("streaming", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);
  }

  @Override
  public void preResult(Context ctx) {
    if (!this.active || !streamable(ctx)) {
      return;
    }
    final Result result = ctx.result;
    if (result == null) {
      return;
    }

    result.streaming = true;
    result.stream = () -> iterate(result);

    this.opened++;
  }

  private Iterator<Object> iterate(Result result) {
    final int chunkDelay = FeatureOptions.foptInt(this.options, "chunkDelay", 0);
    final int chunkSize = FeatureOptions.foptInt(this.options, "chunkSize", 0);
    final IntConsumer sleep = FeatureOptions.foptSleep(this.options);

    // Read lazily at stream() call time so downstream result processing
    // is reflected.
    final List<Object> items = result.resdata instanceof List
        ? (List<Object>) result.resdata
        : new ArrayList<>();

    return new Iterator<Object>() {
      private int index = 0;

      @Override
      public boolean hasNext() {
        return index < items.size();
      }

      @Override
      public Object next() {
        if (!hasNext()) {
          throw new NoSuchElementException();
        }
        if (chunkDelay > 0) {
          sleep.accept(chunkDelay);
        }
        if (chunkSize > 0) {
          int end = Math.min(index + chunkSize, items.size());
          List<Object> batch = new ArrayList<>(items.subList(index, end));
          index = end;
          return batch;
        }
        return items.get(index++);
      }
    };
  }

  private boolean streamable(Context ctx) {
    String opname = "";
    if (ctx.op != null) {
      opname = ctx.op.name;
    }
    List<String> ops = FeatureOptions.foptStrList(this.options, "ops");
    if (ops == null) {
      ops = List.of("list");
    }
    for (String o : ops) {
      if (o.equals(opname)) {
        return true;
      }
    }
    return false;
  }
}
