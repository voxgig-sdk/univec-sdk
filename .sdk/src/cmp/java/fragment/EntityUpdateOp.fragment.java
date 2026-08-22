package JAVAPACKAGE.entity;

import java.util.LinkedHashMap;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.utility.struct.Struct;

// Fragment carrier: only the section between the EJECT markers is spliced
// into the generated entity class (which extends EntityBase).
abstract class EntityUpdateOpFragment extends EntityBase {

  EntityUpdateOpFragment(SdkClient client, Map<String, Object> entopts) {
    super("entityname", client, entopts);
  }

// EJECT-START

  @Override
  public Object update(Map<String, Object> reqdata, Map<String, Object> ctrl) {
    Map<String, Object> ctxmap = new LinkedHashMap<>();
    ctxmap.put("opname", "update");
    ctxmap.put("ctrl", ctrl);
    ctxmap.put("match", this.match);
    ctxmap.put("data", this.data);
    ctxmap.put("reqdata", reqdata);
    Context ctx = this.utility.makeContext.apply(ctxmap, this.entctx);

    return runOp(ctx, () -> {
      if (ctx.result != null) {
        if (ctx.result.resmatch != null) {
          this.match = ctx.result.resmatch;
        }
        if (ctx.result.resdata != null) {
          Map<String, Object> d = Helpers.toMapAny(Struct.clone(ctx.result.resdata));
          this.data = d == null ? new LinkedHashMap<>() : d;
        }
      }
    });
  }

// EJECT-END
}
