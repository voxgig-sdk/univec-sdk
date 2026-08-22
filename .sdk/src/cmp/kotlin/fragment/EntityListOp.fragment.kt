package KOTLINPACKAGE.entity

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.SdkClient

// Fragment carrier: only the section between the EJECT markers is spliced
// into the generated entity class (which extends EntityBase).
@Suppress("UNCHECKED_CAST")
abstract class EntityListOpFragment(clientIn: SdkClient, entoptsIn: MutableMap<String, Any?>?) :
  EntityBase("entityname", clientIn, entoptsIn) {

// EJECT-START

  override fun list(reqmatch: MutableMap<String, Any?>?, ctrl: MutableMap<String, Any?>?): Any? {
    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["opname"] = "list"
    ctxmap["ctrl"] = ctrl
    ctxmap["match"] = this.match
    ctxmap["data"] = this.data
    ctxmap["reqmatch"] = reqmatch
    val ctx = this.utility.makeContext(ctxmap, this.entctx)

    return runOp(ctx) {
      val result = ctx.result
      if (result != null) {
        if (result.resmatch != null) {
          this.match = result.resmatch!!
        }
      }
    }
  }

// EJECT-END
}
