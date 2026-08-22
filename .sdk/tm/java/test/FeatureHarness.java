package JAVAPACKAGE.sdktest;

// Offline feature-test harness: drives features through a faithful
// miniature of the real operation pipeline against a configurable mock
// transport — the same hook order and short-circuit rules as the generated
// entity op code, but with no live server and no API-specific fixtures.
// Mirrors tm/go/test/feature_test.go's fh* helpers.

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.function.Supplier;

import JAVAPACKAGE.core.Config;
import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Feature;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.Operation;
import JAVAPACKAGE.core.UnivecSDK;
import JAVAPACKAGE.core.Response;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.core.SdkError;
import JAVAPACKAGE.core.Spec;
import JAVAPACKAGE.core.Utility;

@SuppressWarnings({"unchecked"})
public final class FeatureHarness {

  private FeatureHarness() {}

  // fhHasFeature is true when this SDK was generated with the named feature.
  public static boolean fhHasFeature(String name) {
    Map<String, Object> config = Config.makeConfig();
    Map<String, Object> fm = Helpers.toMapAny(config.get("feature"));
    return fm != null && fm.get(name) != null;
  }

  // FhClock is a deterministic virtual clock: now() advances only when
  // sleep(ms) is called, so timing-based features can be asserted without
  // real delays.
  public static final class FhClock {
    public long t = 0;

    public long now() {
      return t;
    }

    public void sleep(int ms) {
      t += ms;
    }

    public void advance(int ms) {
      t += ms;
    }
  }

  // fhResponse builds a transport-shaped response the pipeline understands.
  public static Map<String, Object> fhResponse(int status, Object data,
      Map<String, Object> headers) {
    Map<String, Object> h = new LinkedHashMap<>();
    if (headers != null) {
      for (Map.Entry<String, Object> e : headers.entrySet()) {
        h.put(e.getKey().toLowerCase(), e.getValue());
      }
    }
    final Object body = data;
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("status", status);
    out.put("statusText", status >= 400 ? "ERR" : "OK");
    out.put("body", "not-used");
    out.put("json", (Supplier<Object>) () -> body);
    out.put("headers", h);
    return out;
  }

  // FhRecorder is a mock transport recording every call, replying via an
  // optional reply function (default: 200 with a call counter).
  public static class FhRecorder {
    public final List<Map<String, Object>> calls = new ArrayList<>();
    public FhReply reply;

    @FunctionalInterface
    public interface FhReply {
      Object reply(int n, Map<String, Object> fetchdef);
    }

    public Object fetch(Context ctx, String url, Map<String, Object> fetchdef) {
      Map<String, Object> call = new LinkedHashMap<>();
      call.put("url", url);
      call.put("fetchdef", fetchdef);
      calls.add(call);
      if (reply != null) {
        return reply.reply(calls.size(), fetchdef);
      }
      Map<String, Object> data = new LinkedHashMap<>();
      data.put("ok", true);
      data.put("n", calls.size());
      return fhResponse(200, data, null);
    }

    public Map<String, Object> headers(int i) {
      Map<String, Object> fetchdef = Helpers.toMapAny(calls.get(i).get("fetchdef"));
      Map<String, Object> headers = fetchdef == null
          ? null : Helpers.toMapAny(fetchdef.get("headers"));
      return headers == null ? new LinkedHashMap<>() : headers;
    }

    public Map<String, Object> fetchdef(int i) {
      Map<String, Object> fetchdef = Helpers.toMapAny(calls.get(i).get("fetchdef"));
      return fetchdef == null ? new LinkedHashMap<>() : fetchdef;
    }

    public String url(int i) {
      Object url = calls.get(i).get("url");
      return url instanceof String ? (String) url : "";
    }
  }

  // FhFeature pairs a feature instance with its init options.
  public static final class FhFeature {
    public final Feature f;
    public final Map<String, Object> options;

    public FhFeature(Feature f, Map<String, Object> options) {
      this.f = f;
      this.options = options;
    }
  }

  public static FhFeature fhF(Feature f, Map<String, Object> options) {
    return new FhFeature(f, options);
  }

  public static final class FhOpSpec {
    public String entity = "";
    public String op = "";
    public String method = "";
    public String path = "";
    public Map<String, Object> query;
    public Map<String, Object> headers;
    public Object body;
    public Map<String, Object> ctrl;

    public FhOpSpec op(String op) {
      this.op = op;
      return this;
    }

    public FhOpSpec entity(String entity) {
      this.entity = entity;
      return this;
    }

    public FhOpSpec method(String method) {
      this.method = method;
      return this;
    }

    public FhOpSpec path(String path) {
      this.path = path;
      return this;
    }

    public FhOpSpec query(Map<String, Object> query) {
      this.query = query;
      return this;
    }

    public FhOpSpec headers(Map<String, Object> headers) {
      this.headers = headers;
      return this;
    }

    public FhOpSpec body(Object body) {
      this.body = body;
      return this;
    }

    public FhOpSpec ctrl(Map<String, Object> ctrl) {
      this.ctrl = ctrl;
      return this;
    }
  }

  public static FhOpSpec fhOp(String op) {
    return new FhOpSpec().op(op);
  }

  public static final class FhOpResult {
    public boolean ok;
    public Object data;
    public RuntimeException err;
    public Result result;
    public Context ctx;
  }

  public static String fhDefaultMethod(String op) {
    switch (op) {
      case "create":
        return "POST";
      case "update":
        return "PATCH";
      case "remove":
        return "DELETE";
      default:
        return "GET";
    }
  }

  public static String fhBuildUrl(Spec spec) {
    List<String> keys = new ArrayList<>();
    for (Map.Entry<String, Object> e : new TreeMap<>(spec.query).entrySet()) {
      if (e.getValue() != null) {
        keys.add(e.getKey());
      }
    }
    StringBuilder qs = new StringBuilder();
    for (String k : keys) {
      if (qs.length() > 0) {
        qs.append("&");
      }
      qs.append(URLEncoder.encode(k, StandardCharsets.UTF_8))
          .append("=")
          .append(URLEncoder.encode(String.valueOf(spec.query.get(k)),
              StandardCharsets.UTF_8));
    }
    String url = spec.base + spec.path;
    if (qs.length() > 0) {
      url += "?" + qs;
    }
    return url;
  }

  // FhHarness wires features (in init order) to a mock transport and a mini
  // operation pipeline.
  public static final class FhHarness {
    public UnivecSDK client;
    public Utility utility;
    public Context rootctx;
    public String base = "http://api.test";

    // op runs one operation through the mini pipeline (mirrors the
    // generated entity op code: hook, short-circuit, make*, hook, ...).
    public FhOpResult op(FhOpSpec o) {
      String entity = "".equals(o.entity) ? "widget" : o.entity;
      String opname = "".equals(o.op) ? "load" : o.op;
      String method = "".equals(o.method) ? fhDefaultMethod(opname) : o.method;
      Map<String, Object> ctrl = o.ctrl == null ? new LinkedHashMap<>() : o.ctrl;

      Map<String, Object> ctxmap = new LinkedHashMap<>();
      ctxmap.put("opname", opname);
      ctxmap.put("ctrl", ctrl);
      Context ctx = utility.makeContext.apply(ctxmap, rootctx);
      Map<String, Object> opdef = new LinkedHashMap<>();
      opdef.put("entity", entity);
      opdef.put("name", opname);
      ctx.op = new Operation(opdef);

      utility.featureHook.apply(ctx, "PostConstructEntity");

      utility.featureHook.apply(ctx, "PrePoint");
      if (ctx.out.get("point") instanceof RuntimeException) {
        return fail(ctx, (RuntimeException) ctx.out.get("point"));
      }

      utility.featureHook.apply(ctx, "PreSpec");
      String path = "".equals(o.path) || o.path == null ? "/" + entity : o.path;
      Map<String, Object> headers = new LinkedHashMap<>();
      if (o.headers != null) {
        headers.putAll(o.headers);
      }
      Map<String, Object> query = new LinkedHashMap<>();
      if (o.query != null) {
        query.putAll(o.query);
      }
      Map<String, Object> specmap = new LinkedHashMap<>();
      specmap.put("method", method);
      specmap.put("base", base);
      specmap.put("path", path);
      specmap.put("headers", headers);
      specmap.put("query", query);
      specmap.put("step", "start");
      ctx.spec = new Spec(specmap);
      if (o.body != null) {
        ctx.spec.body = o.body;
      }

      utility.featureHook.apply(ctx, "PreRequest");
      ctx.spec.url = fhBuildUrl(ctx.spec);

      Map<String, Object> fetchdef = new LinkedHashMap<>();
      fetchdef.put("url", ctx.spec.url);
      fetchdef.put("method", ctx.spec.method);
      fetchdef.put("headers", ctx.spec.headers);
      if (ctx.spec.body != null) {
        fetchdef.put("body", ctx.spec.body);
      }

      Object response = null;
      RuntimeException fetchErr = null;
      if (ctx.out.get("request") != null) {
        response = ctx.out.get("request");
      }
      else {
        try {
          response = utility.fetcher.fetch(ctx, ctx.spec.url, fetchdef);
        }
        catch (RuntimeException e) {
          fetchErr = e;
        }
      }
      if (response instanceof Map) {
        ctx.response = new Response((Map<String, Object>) response);
      }

      utility.featureHook.apply(ctx, "PreResponse");
      fhPopulateResult(ctx, response, fetchErr);
      utility.featureHook.apply(ctx, "PreResult");
      utility.featureHook.apply(ctx, "PreDone");

      if (ctx.result != null && ctx.result.ok) {
        FhOpResult out = new FhOpResult();
        out.ok = true;
        out.data = ctx.result.resdata;
        out.result = ctx.result;
        out.ctx = ctx;
        return out;
      }

      RuntimeException err;
      if (ctx.result != null && ctx.result.err != null) {
        err = ctx.result.err;
      }
      else {
        err = ctx.makeError("op_failed", "operation failed");
      }
      return fail(ctx, err);
    }

    public FhOpResult fail(Context ctx, RuntimeException err) {
      ctx.ctrl.err = err;
      utility.featureHook.apply(ctx, "PreUnexpected");
      FhOpResult out = new FhOpResult();
      out.ok = false;
      out.err = err;
      out.result = ctx.result;
      out.ctx = ctx;
      return out;
    }
  }

  // fhMake constructs the harness: a real (test-mode) client, an isolated
  // utility whose fetcher is the mock server, and the requested features
  // initialised against it. Fires PostConstruct once wiring is complete.
  public static FhHarness fhMake(Utility.FetcherFn server, FhFeature... features) {
    UnivecSDK client = UnivecSDK.testSDK();
    client.features = new ArrayList<>();

    Utility utility = client.getUtility();
    if (server == null) {
      FhRecorder rec = new FhRecorder();
      server = rec::fetch;
    }
    utility.fetcher = server;

    Map<String, Object> ctxmap = new LinkedHashMap<>();
    ctxmap.put("client", client);
    ctxmap.put("utility", utility);
    Context rootctx = utility.makeContext.apply(ctxmap, client.getRootCtx());

    for (FhFeature fs : features) {
      Map<String, Object> fopts = new LinkedHashMap<>();
      fopts.put("active", true);
      if (fs.options != null) {
        fopts.putAll(fs.options);
      }
      fs.f.init(rootctx, fopts);
      client.features.add(fs.f);
    }

    utility.featureHook.apply(rootctx, "PostConstruct");

    FhHarness h = new FhHarness();
    h.client = client;
    h.utility = utility;
    h.rootctx = rootctx;
    return h;
  }

  static void fhPopulateResult(Context ctx, Object response, RuntimeException fetchErr) {
    Result result = new Result(new LinkedHashMap<>());
    ctx.result = result;

    if (fetchErr != null) {
      result.err = fetchErr;
      return;
    }

    if (!(response instanceof Map)) {
      result.err = ctx.makeError("request_no_response", "response: undefined");
      return;
    }

    Response resp = new Response((Map<String, Object>) response);
    result.status = resp.status;
    result.statusText = resp.statusText;
    Map<String, Object> hm = Helpers.toMapAny(resp.headers);
    if (hm != null) {
      result.headers = hm;
    }
    if (resp.jsonFunc != null) {
      result.body = resp.jsonFunc.get();
    }
    result.resdata = result.body;

    if (result.status >= 400) {
      result.err = ctx.makeError("request_status",
          "request: " + result.status + ": " + result.statusText);
    }
    else if (resp.err != null) {
      result.err = resp.err;
    }
    if (result.err == null) {
      result.ok = true;
    }
  }

  // fhErrCode extracts the SDK error code, "" otherwise.
  public static String fhErrCode(RuntimeException err) {
    if (err instanceof SdkError) {
      return ((SdkError) err).code;
    }
    return "";
  }

  // Small map builder for test options.
  public static Map<String, Object> fhMap(Object... kv) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (int i = 0; i < kv.length - 1; i += 2) {
      out.put(String.valueOf(kv[i]), kv[i + 1]);
    }
    return out;
  }
}
