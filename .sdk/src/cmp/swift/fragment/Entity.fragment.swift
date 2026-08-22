// EntityName entity client for the ProjectName SDK.

import Foundation

public final class EntyClass: ProjectNameEntityBase {
  public init(_ client: ProjectNameSDK, _ entopts: VMap? = nil) {
    super.init(client, entopts, "entityname")
  }

  public override func make() -> Entity {
    return EntyClass(client, cloneOpts())
  }

  // #LoadOp

  // #ListOp

  // #CreateOp

  // #UpdateOp

  // #RemoveOp
}
