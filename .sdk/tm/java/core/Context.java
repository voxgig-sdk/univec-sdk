package JAVAPACKAGE.core;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

import JAVAPACKAGE.utility.struct.Struct;

/** Per-operation context threaded through the pipeline and feature hooks. */
@SuppressWarnings({"unchecked"})
public class Context {

  public String id;
  public Map<String, Object> out = new LinkedHashMap<>();
  public Control ctrl;
  public Map<String, Object> meta;
  public SdkClient client;
  public Utility utility;
  public Operation op;
  public Map<String, Object> point;
  public Map<String, Object> config;
  public Map<String, Object> entopts;
  public Map<String, Object> options;
  public Map<String, Operation> opmap;
  public Response response;
  public Result result;
  public Spec spec;
  public Map<String, Object> data;
  public Map<String, Object> reqdata;
  public Map<String, Object> match;
  public Map<String, Object> reqmatch;
  public Entity entity;
  public Map<String, Object> shared;

  public Context(Map<String, Object> ctxmap, Context basectx) {
    this.id = "C" + (ThreadLocalRandom.current().nextInt(90000000) + 10000000);

    // Client
    Object c = Helpers.getCtxProp(ctxmap, "client");
    if (c instanceof SdkClient) {
      this.client = (SdkClient) c;
    }
    if (this.client == null && basectx != null) {
      this.client = basectx.client;
    }

    // Utility
    Object u = Helpers.getCtxProp(ctxmap, "utility");
    if (u instanceof Utility) {
      this.utility = (Utility) u;
    }
    if (this.utility == null && basectx != null) {
      this.utility = basectx.utility;
    }

    // Ctrl
    this.ctrl = new Control();
    Object cv = Helpers.getCtxProp(ctxmap, "ctrl");
    if (cv != null) {
      if (cv instanceof Map) {
        Map<String, Object> cm = (Map<String, Object>) cv;
        Object t = cm.get("throw");
        if (t instanceof Boolean) {
          this.ctrl.throwing = (Boolean) t;
        }
        Object e = cm.get("explain");
        if (e instanceof Map) {
          this.ctrl.explain = (Map<String, Object>) e;
        }
        Object a = cm.get("actor");
        if (a instanceof String) {
          this.ctrl.actor = (String) a;
        }
        Object p = cm.get("paging");
        if (p instanceof Map) {
          this.ctrl.paging = (Map<String, Object>) p;
        }
      }
      else if (cv instanceof Control) {
        this.ctrl = (Control) cv;
      }
    }
    else if (basectx != null && basectx.ctrl != null) {
      this.ctrl = basectx.ctrl;
    }

    // Meta
    this.meta = new LinkedHashMap<>();
    Object m = Helpers.getCtxProp(ctxmap, "meta");
    if (m instanceof Map) {
      this.meta = (Map<String, Object>) m;
    }
    else if (basectx != null && basectx.meta != null) {
      this.meta = basectx.meta;
    }

    // Config
    Object cfg = Helpers.getCtxProp(ctxmap, "config");
    if (cfg instanceof Map) {
      this.config = (Map<String, Object>) cfg;
    }
    if (this.config == null && basectx != null) {
      this.config = basectx.config;
    }

    // Entopts
    Object eo = Helpers.getCtxProp(ctxmap, "entopts");
    if (eo instanceof Map) {
      this.entopts = (Map<String, Object>) eo;
    }
    if (this.entopts == null && basectx != null) {
      this.entopts = basectx.entopts;
    }

    // Options
    Object o = Helpers.getCtxProp(ctxmap, "options");
    if (o instanceof Map) {
      this.options = (Map<String, Object>) o;
    }
    if (this.options == null && basectx != null) {
      this.options = basectx.options;
    }

    // Entity
    Object e = Helpers.getCtxProp(ctxmap, "entity");
    if (e instanceof Entity) {
      this.entity = (Entity) e;
    }
    if (this.entity == null && basectx != null) {
      this.entity = basectx.entity;
    }

    // Shared
    Object s = Helpers.getCtxProp(ctxmap, "shared");
    if (s instanceof Map) {
      this.shared = (Map<String, Object>) s;
    }
    if (this.shared == null && basectx != null) {
      this.shared = basectx.shared;
    }

    // Opmap
    Object om = Helpers.getCtxProp(ctxmap, "opmap");
    if (om instanceof Map) {
      this.opmap = (Map<String, Operation>) om;
    }
    if (this.opmap == null && basectx != null) {
      this.opmap = basectx.opmap;
    }
    if (this.opmap == null) {
      this.opmap = new LinkedHashMap<>();
    }

    // Data
    this.data = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "data"));
    if (this.data == null) {
      this.data = new LinkedHashMap<>();
    }
    this.reqdata = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "reqdata"));
    if (this.reqdata == null) {
      this.reqdata = new LinkedHashMap<>();
    }
    this.match = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "match"));
    if (this.match == null) {
      this.match = new LinkedHashMap<>();
    }
    this.reqmatch = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "reqmatch"));
    if (this.reqmatch == null) {
      this.reqmatch = new LinkedHashMap<>();
    }

    // Point
    Object t = Helpers.getCtxProp(ctxmap, "point");
    if (t instanceof Map) {
      this.point = (Map<String, Object>) t;
    }
    if (this.point == null && basectx != null) {
      this.point = basectx.point;
    }

    // Spec
    Object sp = Helpers.getCtxProp(ctxmap, "spec");
    if (sp instanceof Spec) {
      this.spec = (Spec) sp;
    }
    if (this.spec == null && basectx != null) {
      this.spec = basectx.spec;
    }

    // Result
    Object r = Helpers.getCtxProp(ctxmap, "result");
    if (r instanceof Result) {
      this.result = (Result) r;
    }
    if (this.result == null && basectx != null) {
      this.result = basectx.result;
    }

    // Response
    Object resp = Helpers.getCtxProp(ctxmap, "response");
    if (resp instanceof Response) {
      this.response = (Response) resp;
    }
    if (this.response == null && basectx != null) {
      this.response = basectx.response;
    }

    // Resolve operation
    Object opname = Helpers.getCtxProp(ctxmap, "opname");
    this.op = resolveOp(opname instanceof String ? (String) opname : "");
  }

  private Operation resolveOp(String opname) {
    // Cache key is `<entity>:<opname>` so two entities with the same op
    // (e.g. both have a "list") get distinct cached Operations. Keying on
    // opname alone caused the first-resolved entity's points to be served
    // to every subsequent entity's call.
    String entname = "";
    if (this.entity != null) {
      entname = this.entity.getName();
    }
    String cacheKey = entname + ":" + opname;

    Operation cached = this.opmap.get(cacheKey);
    if (cached != null) {
      return cached;
    }

    if ("".equals(opname)) {
      return new Operation(new LinkedHashMap<>());
    }

    Object opcfg = Struct.getpath(this.config,
        List.of("entity", entname, "op", opname));

    String input = "match";
    if ("update".equals(opname) || "create".equals(opname)) {
      input = "data";
    }

    List<Object> points = null;
    if (opcfg instanceof Map) {
      Object t = Struct.getprop(opcfg, "points");
      if (t instanceof List) {
        points = (List<Object>) t;
      }
    }
    if (points == null) {
      points = new ArrayList<>();
    }

    Map<String, Object> opdef = new LinkedHashMap<>();
    opdef.put("entity", entname);
    opdef.put("name", opname);
    opdef.put("input", input);
    opdef.put("points", points);

    Operation op = new Operation(opdef);

    this.opmap.put(cacheKey, op);
    return op;
  }

  public SdkError makeError(String code, String msg) {
    return new SdkError(code, msg, this);
  }
}
