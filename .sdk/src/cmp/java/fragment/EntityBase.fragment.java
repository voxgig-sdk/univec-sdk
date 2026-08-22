package JAVAPACKAGE.entity;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Spliterator;
import java.util.Spliterators;
import java.util.function.BooleanSupplier;
import java.util.stream.Stream;
import java.util.stream.StreamSupport;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.SdkEntity;
import JAVAPACKAGE.core.Utility;
import JAVAPACKAGE.utility.struct.Struct;

/**
 * Shared entity runtime for the ProjectName SDK: accreting data/match
 * state, the entity context, and the operation pipeline (runOp) with its
 * feature hooks. Generated entity classes extend this.
 */
@SuppressWarnings({"unchecked"})
public abstract class EntityBase implements SdkEntity {

  protected String name = "";
  protected SdkClient client;
  protected Utility utility;
  protected Map<String, Object> entopts;
  protected Map<String, Object> data = new LinkedHashMap<>();
  protected Map<String, Object> match = new LinkedHashMap<>();
  protected Context entctx;

  // Every operation resolves to the entity; `remove` additionally marks
  // it. The instance KEEPS the data it held — a caller can still read what
  // was deleted — but it is no longer a live record. See AGENTS.md.
  private boolean deleted = false;

  public void markDeleted() {
    this.deleted = true;
  }

  public boolean deleted() {
    return this.deleted;
  }


  protected EntityBase(String name, SdkClient client, Map<String, Object> entopts) {
    if (entopts == null) {
      entopts = new LinkedHashMap<>();
    }
    if (!entopts.containsKey("active")) {
      entopts.put("active", true);
    }
    else if (Boolean.FALSE.equals(entopts.get("active"))) {
      // keep false
    }
    else {
      entopts.put("active", true);
    }

    this.name = name;
    this.client = client;
    this.utility = client.getUtility();
    this.entopts = entopts;

    Map<String, Object> ctxmap = new LinkedHashMap<>();
    ctxmap.put("entity", this);
    ctxmap.put("entopts", entopts);
    this.entctx = this.utility.makeContext.apply(ctxmap, client.getRootCtx());

    this.utility.featureHook.apply(this.entctx, "PostConstructEntity");
  }

  @Override
  public String getName() {
    return this.name;
  }

  @Override
  public Object data(Object... args) {
    if (args.length > 0 && args[0] != null) {
      Map<String, Object> d = Helpers.toMapAny(Struct.clone(args[0]));
      this.data = d == null ? new LinkedHashMap<>() : d;
      this.utility.featureHook.apply(this.entctx, "SetData");
    }

    this.utility.featureHook.apply(this.entctx, "GetData");
    return Struct.clone(this.data);
  }

  @Override
  public Object match(Object... args) {
    if (args.length > 0 && args[0] != null) {
      Map<String, Object> m = Helpers.toMapAny(Struct.clone(args[0]));
      this.match = m == null ? new LinkedHashMap<>() : m;
      this.utility.featureHook.apply(this.entctx, "SetMatch");
    }

    this.utility.featureHook.apply(this.entctx, "GetMatch");
    return Struct.clone(this.match);
  }

  // runOp drives one operation through the pipeline: for each stage the
  // feature hook fires, then the stage runs; a failing stage routes
  // through makeError (which throws, or returns fallback data when
  // ctrl.throw is false).
  protected Object runOp(Context ctx, Runnable postDone) {
    Utility utility = this.utility;

    try {
// #PrePoint-Hook

      Object point = utility.makePoint.apply(ctx);
      ctx.out.put("point", point);

// #PreSpec-Hook

      Object spec = utility.makeSpec.apply(ctx);
      ctx.out.put("spec", spec);

// #PreRequest-Hook

      Object request = utility.makeRequest.apply(ctx);
      ctx.out.put("request", request);

// #PreResponse-Hook

      Object response = utility.makeResponse.apply(ctx);
      ctx.out.put("response", response);

// #PreResult-Hook

      Object result = utility.makeResult.apply(ctx);
      ctx.out.put("result", result);

// #PreDone-Hook

      postDone.run();

      Object out = utility.done.apply(ctx);

      // An operation resolves to the ENTITY, not the raw data. Entities are
      // stateful: postDone has just absorbed resdata/resmatch into this
      // instance, and the caller reaches the record through data(). Two
      // structural exceptions: `list` resolves to the ARRAY of entity
      // instances makeResult built, and a failed op with throwing disabled
      // hands back the error payload unchanged. `remove` additionally marks
      // the entity deleted; it KEEPS its data, so a caller can still read
      // what was removed. See AGENTS.md "Entity operations return ENTITIES".
      String opname = ctx.op == null ? null : ctx.op.name;

      if (ctx.result != null && ctx.result.ok && !"list".equals(opname)) {
        if ("remove".equals(opname)) {
          this.markDeleted();
        }
        return this;
      }

      return out;
    }
    catch (RuntimeException err) {
      // An error already finalised by makeError (e.g. via done) must not
      // be wrapped a second time.
      if (err == ctx.ctrl.err) {
        throw err;
      }
      return utility.makeError.apply(ctx, err);
    }
  }

  /**
   * Streaming operations. Runs `action` through the full pipeline and
   * returns a Stream over result items, so the streaming feature's
   * incremental output is reachable from a generated entity (a normal op
   * call materialises the whole result). `callopts` parameterises the call:
   *   - inbound (download): iterate the yielded items/chunks (from the
   *     streaming feature when active, else the materialised items);
   *   - outbound (upload): pass a streamable payload as callopts["body"] - it
   *     is attached to the request so the transport can send it;
   *   - callopts["ctrl"] threads pipeline control and callopts["signal"] (a
   *     BooleanSupplier that returns true when aborted) is honoured between
   *     yields.
   */
  public Stream<Object> stream(
      String action, Map<String, Object> args, Map<String, Object> callopts) {
    Utility utility = this.utility;

    if (callopts == null) {
      callopts = new LinkedHashMap<>();
    }

    Object signalObj = callopts.get("signal");
    final BooleanSupplier signal =
        signalObj instanceof BooleanSupplier ? (BooleanSupplier) signalObj : null;

    Map<String, Object> ctrl = Helpers.toMapAny(callopts.get("ctrl"));
    if (ctrl == null) {
      ctrl = new LinkedHashMap<>();
    }
    ctrl.put("stream", callopts);

    Map<String, Object> ctxmap = new LinkedHashMap<>();
    ctxmap.put("opname", action);
    ctxmap.put("ctrl", ctrl);
    ctxmap.put("match", this.match);
    ctxmap.put("data", this.data);
    if (args != null) {
      ctxmap.putAll(args);
    }

    Context ctx = this.utility.makeContext.apply(ctxmap, this.entctx);

    // Outbound: expose the caller's streamable payload so the request
    // builder / transport can stream it as the request body.
    Object body = callopts.get("body");
    if (body != null) {
      ctx.reqdata.put("body$", body);
      ctx.ctrl.streamOut = body;
    }

    // Run the same pipeline the op methods run.
    Object materialised = runOp(ctx, () -> {});

    // Inbound: prefer the streaming feature's incremental iterator; else fall
    // back to the materialised items so `stream` always yields.
    Iterator<Object> source;
    if (ctx.result != null && ctx.result.stream != null) {
      source = ctx.result.stream.get();
    }
    else {
      List<Object> items;
      if (materialised instanceof List) {
        items = (List<Object>) materialised;
      }
      else if (materialised == null) {
        items = new ArrayList<>();
      }
      else {
        items = new ArrayList<>();
        items.add(materialised);
      }
      source = items.iterator();
    }

    final Iterator<Object> src = source;
    Iterator<Object> guarded = new Iterator<Object>() {
      @Override
      public boolean hasNext() {
        if (signal != null && signal.getAsBoolean()) {
          return false;
        }
        return src.hasNext();
      }

      @Override
      public Object next() {
        return src.next();
      }
    };

    return StreamSupport.stream(
        Spliterators.spliteratorUnknownSize(guarded, Spliterator.ORDERED), false);
  }
}
