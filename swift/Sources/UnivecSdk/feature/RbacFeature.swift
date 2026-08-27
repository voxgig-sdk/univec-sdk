// Client-side role/permission enforcement. Before an operation resolves its
// endpoint, the required permission for that entity+operation is checked
// against the permissions the client holds; a disallowed call is
// short-circuited with an `rbac_denied` error (via ctx.out["point"], which
// makePoint surfaces) and never touches the network. Required permissions
// come from `rules` (keyed by `<entity>.<op>`, `<op>`, or `*`); the default
// when no rule matches is controlled by `deny` (default: allow when
// unspecified). Held permissions are the `permissions` list (a `*` grants
// everything).

import Foundation

public final class RbacFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?
  private var granted: Set<String> = []

  // Activity tracking (mirrors the ts client._rbac record).
  public var allowed = 0
  public var denied = 0
  public var last: VMap?

  public override init() {
    super.init()
    version = "0.0.1"
    name = "rbac"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)

    granted = []
    for p in foptStrList(options, "permissions") ?? [] {
      granted.insert(p)
    }
  }

  public override func prePoint(_ ctx: Context) {
    if !active {
      return
    }

    let (required, has) = requiredPerm(ctx)
    if !has {
      // No rule: honour the default policy.
      if foptBool(options, "deny", false) {
        reject(ctx, "<default-deny>")
      }
      return
    }

    if granted.contains("*") || granted.contains(required) {
      track(ctx, required, true)
      return
    }

    reject(ctx, required)
  }

  private func requiredPerm(_ ctx: Context) -> (String, Bool) {
    guard let rules = foptMap(options, "rules") else {
      return ("", false)
    }

    let entity = ctx.entity?.getName() ?? ctx.op?.entity ?? ""
    let opname = ctx.op?.name ?? ""

    for key in [entity + "." + opname, opname, "*"] {
      if let rs = gp(rules, key).asString {
        return (rs, true)
      }
    }
    return ("", false)
  }

  private func reject(_ ctx: Context, _ required: String) {
    track(ctx, required, false)

    let opname = ctx.op?.name ?? "?"
    let err = ctx.makeError("rbac_denied",
      "Permission \"" + required + "\" required for operation \"" + opname + "\"")

    // Short-circuit endpoint resolution; makePoint surfaces this error
    // before any network activity.
    ctx.out["point"] = err
  }

  private func track(_ ctx: Context, _ required: String, _ isAllowed: Bool) {
    if isAllowed {
      allowed += 1
    } else {
      denied += 1
    }
    let l = VMap()
    l.entries["required"] = .string(required)
    l.entries["allowed"] = .bool(isAllowed)
    l.entries["op"] = .string(ctx.op?.name ?? "")
    last = l
  }
}
