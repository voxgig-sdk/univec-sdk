package JAVAPACKAGE.feature;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.SdkClient;

// Request/response capture for debugging. Records a bounded ring buffer of
// per-operation traces — method, URL, redacted headers, response status and
// timing — on the feature's entries. Sensitive header values (matching
// `redact`, default authorization/cookie/api-key style names) are masked.
// An optional `onEntry` callback receives each finished entry (e.g. to
// stream to a console). `max` caps the buffer (default 100).
@SuppressWarnings({"unchecked"})
public class DebugFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;

  // Activity tracking (mirrors the ts client._debug record).
  public List<Map<String, Object>> entries = new ArrayList<>();

  private static final String DEBUG_ENTRY_KEY = "debug_entry";

  private static final List<String> DEFAULT_REDACT = List.of(
      "authorization", "cookie", "set-cookie", "api-key", "apikey",
      "x-api-key", "idempotency-key");

  public DebugFeature() {
    super("debug", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);
  }

  @Override
  public void preRequest(Context ctx) {
    if (!this.active) {
      return;
    }

    String entity = "_";
    String opname = "_";
    if (ctx.op != null) {
      entity = ctx.op.entity;
      opname = ctx.op.name;
    }

    Map<String, Object> entry = new LinkedHashMap<>();
    entry.put("op", entity + "." + opname);
    entry.put("start", FeatureOptions.foptNow(this.options).getAsLong());
    if (ctx.spec != null) {
      entry.put("method", ctx.spec.method);
      if (!"".equals(ctx.spec.url)) {
        entry.put("url", ctx.spec.url);
      }
      else {
        entry.put("url", ctx.spec.path);
      }
      entry.put("headers", redact(ctx.spec.headers));
    }
    ctx.out.put(DEBUG_ENTRY_KEY, entry);
  }

  @Override
  public void preResponse(Context ctx) {
    if (!this.active) {
      return;
    }

    Map<String, Object> entry = Helpers.toMapAny(ctx.out.get(DEBUG_ENTRY_KEY));
    if (entry == null) {
      return;
    }
    if (ctx.response != null) {
      entry.put("status", ctx.response.status);
      Object url = entry.get("url");
      if ((url == null || "".equals(url)) && ctx.spec != null) {
        entry.put("url", ctx.spec.url);
      }
    }
  }

  @Override
  public void preDone(Context ctx) {
    finish(ctx, true);
  }

  @Override
  public void preUnexpected(Context ctx) {
    Map<String, Object> entry = Helpers.toMapAny(ctx.out.get(DEBUG_ENTRY_KEY));
    if (entry != null && ctx.ctrl != null && ctx.ctrl.err != null) {
      entry.put("error", ctx.ctrl.err.getMessage());
    }
    finish(ctx, false);
  }

  private void finish(Context ctx, boolean ok) {
    // Finish once per operation: the marker in ctx.out is consumed here.
    Map<String, Object> entry = Helpers.toMapAny(ctx.out.get(DEBUG_ENTRY_KEY));
    if (entry == null) {
      return;
    }
    ctx.out.remove(DEBUG_ENTRY_KEY);

    entry.put("ok", ok && (ctx.result == null || ctx.result.ok));
    long start = Helpers.toLong(entry.get("start"), 0);
    long dur = FeatureOptions.foptNow(this.options).getAsLong() - start;
    if (dur < 0) {
      dur = 0;
    }
    entry.put("durationMs", dur);
    if (entry.get("status") == null && ctx.result != null) {
      entry.put("status", ctx.result.status);
    }

    this.entries.add(entry);
    int max = FeatureOptions.foptInt(this.options, "max", 100);
    while (this.entries.size() > max) {
      this.entries.remove(0);
    }

    if (this.options.get("onEntry") instanceof Consumer) {
      ((Consumer<Map<String, Object>>) this.options.get("onEntry")).accept(entry);
    }
  }

  private Map<String, Object> redact(Map<String, Object> headers) {
    Map<String, Object> out = new LinkedHashMap<>();
    if (headers == null) {
      return out;
    }
    List<String> patterns = FeatureOptions.foptStrList(this.options, "redact");
    if (patterns == null) {
      patterns = DEFAULT_REDACT;
    }
    for (Map.Entry<String, Object> h : headers.entrySet()) {
      boolean masked = false;
      for (String p : patterns) {
        if (h.getKey().toLowerCase().equals(p)) {
          masked = true;
          break;
        }
      }
      if (masked) {
        out.put(h.getKey(), "<redacted>");
      }
      else {
        out.put(h.getKey(), h.getValue());
      }
    }
    return out;
  }
}
