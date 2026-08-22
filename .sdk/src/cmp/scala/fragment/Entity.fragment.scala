package SCALAPACKAGE.entity

import java.util.{LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core.{Context, Entity, Helpers, SdkClient}
import SCALAPACKAGE.utility.struct.Struct

// EntityName entity client for the ProjectName SDK.
class EntyClass(client0: SdkClient, entopts0: JMap[String, Object]) extends EntityBase("entityname", client0, entopts0) {

  override def make(): Entity = {
    val opts = new LinkedHashMap[String, Object](this.entopts)
    new EntyClass(this.client, opts)
  }

// #LoadOp

// #ListOp

// #CreateOp

// #UpdateOp

// #RemoveOp
}
