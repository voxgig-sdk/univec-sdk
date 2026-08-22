// Univec SDK - feature base class. Features derive from this and override
// the hooks they need; unimplemented hooks are no-ops. Hook dispatch is by
// name (the Swift twin of the go/csharp reflective dispatch).

import Foundation

open class BaseFeature {
  public var version = "0.0.1"
  public var name = "base"
  public var active = true

  // addOpts positions this feature when added via the client `extend` option:
  // "__before__", "__after__" or "__replace__" name an already-added feature.
  public var addOpts: VMap?

  public init() {}

  open func addOptions() -> VMap? { addOpts }
  open func getVersion() -> String { version }
  open func getName() -> String { name }
  open func getActive() -> Bool { active }

  open func initFeature(_ ctx: Context, _ options: VMap) {}

  open func postConstruct(_ ctx: Context) {}
  open func postConstructEntity(_ ctx: Context) {}
  open func setData(_ ctx: Context) {}
  open func getData(_ ctx: Context) {}
  open func getMatch(_ ctx: Context) {}
  open func setMatch(_ ctx: Context) {}
  open func prePoint(_ ctx: Context) {}
  open func preSpec(_ ctx: Context) {}
  open func preRequest(_ ctx: Context) {}
  open func preResponse(_ ctx: Context) {}
  open func preResult(_ ctx: Context) {}
  open func preDone(_ ctx: Context) {}
  open func preUnexpected(_ ctx: Context) {}

  // Non-standard hooks (unknown hook names route here).
  open func customHook(_ name: String, _ ctx: Context) {}

  public func dispatch(_ name: String, _ ctx: Context) {
    switch name {
    case "PostConstruct": postConstruct(ctx)
    case "PostConstructEntity": postConstructEntity(ctx)
    case "SetData": setData(ctx)
    case "GetData": getData(ctx)
    case "GetMatch": getMatch(ctx)
    case "SetMatch": setMatch(ctx)
    case "PrePoint": prePoint(ctx)
    case "PreSpec": preSpec(ctx)
    case "PreRequest": preRequest(ctx)
    case "PreResponse": preResponse(ctx)
    case "PreResult": preResult(ctx)
    case "PreDone": preDone(ctx)
    case "PreUnexpected": preUnexpected(ctx)
    default: customHook(name, ctx)
    }
  }
}
