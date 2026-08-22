package KOTLINPACKAGE.entity

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.SdkClient
import KOTLINPACKAGE.utility.struct.Struct

// Fragment carrier: only the section between the EJECT markers is spliced
// into the generated entity class (which extends EntityBase).
@Suppress("UNCHECKED_CAST")
abstract class EntityCreateOpFragment(clientIn: SdkClient, entoptsIn: MutableMap<String, Any?>?) :
  EntityBase("entityname", clientIn, entoptsIn) {

// EJECT-START

  override fun create(reqdata: MutableMap<String, Any?>?, ctrl: MutableMap<String, Any?>?): Any? {
    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["opname"] = "create"
    ctxmap["ctrl"] = ctrl
    ctxmap["match"] = this.match
    ctxmap["data"] = this.data
    ctxmap["reqdata"] = reqdata
    val ctx = this.utility.makeContext(ctxmap, this.entctx)

    return runOp(ctx) {
      val result = ctx.result
      if (result != null) {
        if (result.resdata != null) {
          val d = Helpers.toMapAny(Struct.clone(result.resdata))
          this.data = d ?: linkedMapOf()
        }
      }
    }
  }

// EJECT-END
}
