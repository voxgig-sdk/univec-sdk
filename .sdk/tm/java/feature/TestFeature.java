package JAVAPACKAGE.feature;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;
import java.util.function.Supplier;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.Operation;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Utility;
import JAVAPACKAGE.utility.struct.Struct;

/**
 * In-memory mock transport for offline testing. Serves entity fixtures
 * (options.entity) through the normal pipeline, and optionally simulates
 * network conditions via the `net` block (latency, failures, outages) —
 * mirroring the ts test feature exactly.
 */
@SuppressWarnings({"unchecked"})
public class TestFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;
  private int netcalls = 0;

  // How many path segments a point has, and whether its path ends in a
  // parameter — the rule makePoint uses to tell the entity's own route from a
  // cross-reference that also returns it.
  @SuppressWarnings("unchecked")
  private static int pointPartsLen(Object point) {
    Object parts = Struct.getprop(point, "parts");
    return parts instanceof List ? ((List<Object>) parts).size() : 0;
  }

  @SuppressWarnings("unchecked")
  private static boolean pointTerminalParam(Object point) {
    Object parts = Struct.getprop(point, "parts");
    if (!(parts instanceof List)) {
      return false;
    }
    List<Object> list = (List<Object>) parts;
    if (list.isEmpty()) {
      return false;
    }
    Object last = list.get(list.size() - 1);
    return last instanceof String && ((String) last).startsWith("{");
  }

  public TestFeature() {
    super("test", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;

    final Map<String, Object> entity =
        Helpers.toMapAny(Struct.getprop(options, "entity"));

    this.client.mode = "test";

    // Ensure entity ids are correct.
    Struct.walk(entity, (key, val, parent, path) -> {
      if (path != null && path.size() == 2 && val instanceof Map && key != null) {
        ((Map<String, Object>) val).put("id", key);
      }
      return val;
    });

    final Map<String, Object> entities =
        entity == null ? new LinkedHashMap<>() : entity;

    Utility.FetcherFn testFetcher = (fctx, fullurl, fetchdef) ->
        this.serve(fctx, entities);

    // Optional network behaviour simulation over the mock transport. Enable
    // per test via `testSDK({"net": ...}, null)`. When `net` is absent the
    // mock behaves exactly as before (no wrapping), so existing generated
    // tests are unaffected.
    Map<String, Object> net = Helpers.toMapAny(Struct.getprop(options, "net"));
    if (net == null) {
      ctx.utility.fetcher = testFetcher;
    }
    else {
      ctx.utility.fetcher = makeNetsim(net, testFetcher);
    }
  }

  // THE MOCK HAS TO AGREE WITH THE MODEL.
  //
  // A point carrying `transform.res: `body.item`` describes an API that
  // answers {"item": {...}}, and the response transform unwraps that key on
  // the way back. Handing back the bare payload means the transform unwraps a
  // property that is not there and the caller gets nothing — a mock that only
  // ever simulates APIs whose responses happen to be unwrapped.
  //
  // Mirrors the go/ts/lua/php mocks, which already wrap.
  private Object envelope(Context ctx, Object data) {
    if (null == data || null == ctx || null == ctx.point) {
      return data;
    }
    Object tm = Struct.getprop(ctx.point, "transform");
    Object restf = Struct.getprop(tm, "res");
    if (!(restf instanceof String)) {
      return data;
    }
    String spec = (String) restf;
    // Exactly `body.<key>`; a deeper path is not an envelope this mock can
    // synthesise, so it is left alone rather than guessed at.
    if (!spec.startsWith("`body.") || !spec.endsWith("`") || spec.length() < 8) {
      return data;
    }
    String inner = spec.substring(6, spec.length() - 1);
    if (inner.isEmpty() || inner.contains(".")) {
      return data;
    }
    Map<String, Object> wrapped = new LinkedHashMap<>();
    wrapped.put(inner, data);
    return wrapped;
  }

  private Map<String, Object> respond(Context ctx, int status, Object data, Map<String, Object> extra) {
    Object payload = envelope(ctx, data);
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("status", status);
    out.put("statusText", "OK");
    out.put("json", (Supplier<Object>) () -> payload);
    out.put("body", "not-used");
    if (extra != null) {
      out.putAll(extra);
    }
    return out;
  }

  private Map<String, Object> extra(String key, Object val) {
    Map<String, Object> out = new LinkedHashMap<>();
    out.put(key, val);
    return out;
  }

  // For single-entity ops (load, remove) with an empty explicit match,
  // fall back to the id the entity client already knows from a prior
  // create/load (in ctx.match / ctx.data). Mirrors the TS mock where
  // param() resolves the id from that accumulated state.
  private Map<String, Object> resolveMatch(Context ctx, Map<String, Object> explicit) {
    if (explicit != null && !explicit.isEmpty()) {
      return explicit;
    }
    for (Map<String, Object> src : new Map[] { ctx.match, ctx.data }) {
      if (src == null) {
        continue;
      }
      Object v = Struct.getprop(src, "id", null);
      if (v != null && !"__UNDEFINED__".equals(v)) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("id", v);
        return out;
      }
    }
    return new LinkedHashMap<>();
  }

  private Object serve(Context ctx, Map<String, Object> entity) {
    Operation op = ctx.op;
    Map<String, Object> entmap = Helpers.toMapAny(Struct.getprop(entity, op.entity));
    if (entmap == null) {
      entmap = new LinkedHashMap<>();
    }

    if ("load".equals(op.name)) {
      Object args = buildArgs(ctx, op, resolveMatch(ctx, ctx.reqmatch));
      List<Object> found = Struct.select(entmap, args);
      Object ent = Struct.getelem(found, 0);
      if (ent == null) {
        return respond(ctx, 404, null, extra("statusText", "Not found"));
      }
      Struct.delprop(ent, "$KEY");
      Object out = Struct.clone(ent);
      return respond(ctx, 200, out, null);
    }
    else if ("list".equals(op.name)) {
      Object args = buildArgs(ctx, op, ctx.reqmatch);
      List<Object> found = Struct.select(entmap, args);
      if (found == null) {
        return respond(ctx, 404, null, extra("statusText", "Not found"));
      }
      for (Object item : found) {
        Struct.delprop(item, "$KEY");
      }
      Object out = Struct.clone(found);
      return respond(ctx, 200, out, null);
    }
    else if ("update".equals(op.name)) {
      // Match the existing entity by id only (or its alias). Reqdata
      // also contains the new field values, which would otherwise
      // cause select to filter out the entity we want to update.
      // When reqdata has no id, fall back to the id the entity
      // client carries from a prior create/load (in ctx.match /
      // ctx.data), mirroring the TS mock where param(ctx,'id')
      // resolves from accumulated state.
      Map<String, Object> updateMatch = new LinkedHashMap<>();
      if (ctx.reqdata != null) {
        if (ctx.reqdata.containsKey("id")) {
          updateMatch.put("id", ctx.reqdata.get("id"));
        }
        if (op.alias != null) {
          Object aliasIdRaw = Struct.getprop(op.alias, "id");
          if (aliasIdRaw instanceof String) {
            String aliasId = (String) aliasIdRaw;
            if (ctx.reqdata.containsKey(aliasId)) {
              updateMatch.put(aliasId, ctx.reqdata.get(aliasId));
            }
          }
        }
      }
      if (updateMatch.isEmpty()) {
        updateMatch = resolveMatch(ctx, new LinkedHashMap<>());
      }
      Object args = buildArgs(ctx, op, updateMatch);
      List<Object> found = Struct.select(entmap, args);
      Object ent = Struct.getelem(found, 0);
      if (ent == null && entmap != null) {
        for (Object e : entmap.values()) {
          if (e instanceof Map) {
            ent = e;
            break;
          }
        }
      }
      if (ent == null) {
        return respond(ctx, 404, null, extra("statusText", "Not found"));
      }
      if (ent instanceof Map && ctx.reqdata != null) {
        ((Map<String, Object>) ent).putAll(ctx.reqdata);
      }
      Struct.delprop(ent, "$KEY");
      Object out = Struct.clone(ent);
      return respond(ctx, 200, out, null);
    }
    else if ("remove".equals(op.name)) {
      Object args = buildArgs(ctx, op, resolveMatch(ctx, ctx.reqmatch));
      List<Object> found = Struct.select(entmap, args);
      Object ent = Struct.getelem(found, 0);
      // Remove only the first matched entity. If nothing matches,
      // succeed as a no-op rather than erroring.
      if (ent instanceof Map) {
        Object id = Struct.getprop(ent, "id", null);
        Struct.delprop(entmap, id);
      }
      return respond(ctx, 200, null, null);
    }
    else if ("create".equals(op.name)) {
      buildArgs(ctx, op, ctx.reqdata);
      Object id = ctx.utility.param.apply(ctx, "id");
      if (id == null) {
        ThreadLocalRandom r = ThreadLocalRandom.current();
        id = String.format("%04x%04x%04x%04x",
            r.nextInt(0x10000), r.nextInt(0x10000),
            r.nextInt(0x10000), r.nextInt(0x10000));
      }

      Object ent = Struct.clone(ctx.reqdata);
      if (ent instanceof Map) {
        Map<String, Object> entm = (Map<String, Object>) ent;
        entm.put("id", id);
        if (id instanceof String) {
          entmap.put((String) id, entm);
        }
        Struct.delprop(entm, "$KEY");
        Object out = Struct.clone(entm);
        return respond(ctx, 200, out, null);
      }
      return respond(ctx, 200, ent, null);
    }

    return respond(ctx, 404, null, extra("statusText", "Unknown operation"));
  }

  // makeNetsim wraps a transport with simulated network conditions: latency
  // (fixed or {min,max}), a budget of first-N failures (`failTimes` ->
  // `failStatus`), first-N connection errors (`errorTimes`), or a hard
  // `offline` outage. Counter-driven, so simulations are deterministic
  // across a test.
  private Utility.FetcherFn makeNetsim(Map<String, Object> net, Utility.FetcherFn inner) {
    this.netcalls = 0;

    return (ctx, url, fetchdef) -> {
      this.netcalls++;
      int call = this.netcalls;

      if (FeatureOptions.foptBool(net, "offline", false)) {
        netSleep(net, pickLatency(net));
        throw ctx.makeError("netsim_offline",
            "Simulated network offline (URL was: \"" + url + "\")");
      }
      if (call <= FeatureOptions.foptInt(net, "errorTimes", 0)) {
        netSleep(net, pickLatency(net));
        throw ctx.makeError("netsim_conn",
            "Simulated connection error (call " + call + ")");
      }
      if (call <= FeatureOptions.foptInt(net, "failTimes", 0)) {
        netSleep(net, pickLatency(net));
        int status = FeatureOptions.foptInt(net, "failStatus", 503);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("status", status);
        out.put("statusText", "Simulated Failure");
        out.put("body", "not-used");
        out.put("json", (Supplier<Object>) () -> null);
        out.put("headers", new LinkedHashMap<String, Object>());
        return out;
      }
      netSleep(net, pickLatency(net));
      return inner.fetch(ctx, url, fetchdef);
    };
  }

  private int pickLatency(Map<String, Object> net) {
    Object l = net.get("latency");
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
      return min + ((max - min) >> 1);
    }
    int fixed = FeatureOptions.foptInt(net, "latency", 0);
    return fixed < 0 ? 0 : fixed;
  }

  private void netSleep(Map<String, Object> net, int ms) {
    if (ms <= 0) {
      return;
    }
    FeatureOptions.foptSleep(net).accept(ms);
  }

  private Object buildArgs(Context ctx, Operation op, Map<String, Object> args) {
    String opname = op.name;

    // Pick the entity's own endpoint from config, not a cross-reference from
    // another resource that also returns it — the same rule makePoint falls
    // back to, so the seed-data query is built from the endpoint the request
    // will actually be sent to: a terminal `{id}` marks a record route, and
    // failing that the shallower path wins.
    Object points = Struct.getpath(ctx.config,
        List.of("entity", ctx.entity == null ? "" : ctx.entity.getName(),
            "op", opname, "points"));
    Object point = Struct.getelem(points, 0);
    if (points instanceof List) {
      for (Object cand : (List<Object>) points) {
        boolean candTerm = pointTerminalParam(cand);
        boolean bestTerm = pointTerminalParam(point);
        if (candTerm != bestTerm) {
          if (candTerm) {
            point = cand;
          }
        } else if (pointPartsLen(cand) < pointPartsLen(point)) {
          point = cand;
        }
      }
    }

    // Get required params.
    Object paramsPath = Struct.getpath(point, List.of("args", "params"));
    Object reqdParams = Struct.select(paramsPath, Struct.jm("reqd", true));
    Object reqd = Struct.transform(reqdParams,
        Struct.jt("`$EACH`", "", "`$KEY.name`"));

    List<Object> qand = Struct.jt();
    Map<String, Object> q = Struct.jm("`$AND`", qand);

    if (args != null) {
      for (String key : Struct.keysof(args)) {
        boolean isId = "id".equals(key);
        List<Object> selected = Struct.select(reqd, key);
        boolean isReqd = !Struct.isempty(selected);

        if (isId || isReqd) {
          Object v = ctx.utility.param.apply(ctx, key);
          Object ka = Struct.getprop(op.alias, key);

          List<Object> qor = Struct.jt(Struct.jm(key, v));
          if (ka instanceof String) {
            qor.add(Struct.jm((String) ka, v));
          }

          qand.add(Struct.jm("`$OR`", qor));
        }
      }
    }

    if (ctx.ctrl.explain != null) {
      ctx.ctrl.explain.put("test", Struct.jm("query", q));
    }

    return q;
  }
}
