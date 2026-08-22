package SCALAPACKAGE.entity

import java.util.{LinkedHashMap, Map => JMap}
import SCALAPACKAGE.core.{Helpers, SdkClient}
import SCALAPACKAGE.utility.struct.Struct

abstract class EntityRemoveOpFragment(client: SdkClient, entopts: JMap[String, Object])
    extends EntityBase("entityname", client, entopts) {

// EJECT-START

  override def remove(reqmatch: JMap[String, Object], ctrl: JMap[String, Object]): Object = {
    val ctxmap = new LinkedHashMap[String, Object]()
    ctxmap.put("opname", "remove")
    ctxmap.put("ctrl", ctrl)
    ctxmap.put("match", this.matchState)
    ctxmap.put("data", this.dataState)
    ctxmap.put("reqmatch", reqmatch)
    val ctx = this.utility.makeContext(ctxmap, this.entctx)

    runOp(ctx, () => {
      if (ctx.result != null) {
        if (ctx.result.resmatch != null) this.matchState = ctx.result.resmatch
        if (ctx.result.resdata != null) {
          val d = Helpers.toMapAny(Struct.clone(ctx.result.resdata))
          this.dataState = if (d == null) new LinkedHashMap[String, Object]() else d
        }
      }
    })
  }

// EJECT-END
}
