package SCALAPACKAGE.entity

import java.util.{LinkedHashMap, Map => JMap}
import SCALAPACKAGE.core.SdkClient

abstract class EntityListOpFragment(client: SdkClient, entopts: JMap[String, Object])
    extends EntityBase("entityname", client, entopts) {

// EJECT-START

  override def list(reqmatch: JMap[String, Object], ctrl: JMap[String, Object]): Object = {
    val ctxmap = new LinkedHashMap[String, Object]()
    ctxmap.put("opname", "list")
    ctxmap.put("ctrl", ctrl)
    ctxmap.put("match", this.matchState)
    ctxmap.put("data", this.dataState)
    ctxmap.put("reqmatch", reqmatch)
    val ctx = this.utility.makeContext(ctxmap, this.entctx)

    runOp(ctx, () => {
      if (ctx.result != null) {
        if (ctx.result.resmatch != null) this.matchState = ctx.result.resmatch
      }
    })
  }

// EJECT-END
}
