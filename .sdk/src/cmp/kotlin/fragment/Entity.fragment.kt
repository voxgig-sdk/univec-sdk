package KOTLINPACKAGE.entity

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Entity
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.SdkClient
import KOTLINPACKAGE.utility.struct.Struct

/** EntityName entity client for the ProjectName SDK. */
@Suppress("UNCHECKED_CAST", "UNUSED_PARAMETER", "UNUSED_VARIABLE")
class EntyClass(clientIn: SdkClient, entoptsIn: MutableMap<String, Any?>?) :
  EntityBase("entityname", clientIn, entoptsIn) {

  override fun make(): Entity {
    val opts = LinkedHashMap(this.entopts)
    return EntyClass(this.client, opts)
  }

// #LoadOp

// #ListOp

// #CreateOp

// #UpdateOp

// #RemoveOp
}
