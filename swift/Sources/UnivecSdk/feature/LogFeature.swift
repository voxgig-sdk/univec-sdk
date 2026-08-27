// Structured hook logging. When active, every pipeline hook is written to the
// configured logger: an injected `logger` closure or, by default, a simple
// stderr text logger honouring `level` (debug|info|warn|error; default info).

import Foundation

public final class LogFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?
  private var logger: ((String, String, VMap) -> Void)?

  public override init() {
    super.init()
    version = "0.0.1"
    name = "log"
    active = true
  }

  private static let levels: [String: Int] = ["debug": 0, "info": 1, "warn": 2, "error": 3]

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options

    if let a = gp(options, "active").asBool { active = a }

    if active {
      if let lg = gp(options, "logger").asNative as? (String, String, VMap) -> Void {
        logger = lg
      } else {
        let minLevel = LogFeature.levels[foptStr(options, "level", "info")] ?? 1
        logger = { level, msg, attrs in
          let n = LogFeature.levels[level] ?? 1
          if n < minLevel { return }
          let parts = attrs.entries.map { "\($0.key)=\(stringify($0.value))" }
          let line = "level=\(level.uppercased()) name=log msg=\(msg) "
            + parts.joined(separator: " ") + "\n"
          FileHandle.standardError.write(line.data(using: .utf8)!)
        }
      }
    }
  }

  public override func postConstruct(_ ctx: Context) { loghook("PostConstruct", ctx, "") }
  public override func postConstructEntity(_ ctx: Context) { loghook("PostConstructEntity", ctx, "") }
  public override func setData(_ ctx: Context) { loghook("SetData", ctx, "") }
  public override func getData(_ ctx: Context) { loghook("GetData", ctx, "") }
  public override func setMatch(_ ctx: Context) { loghook("SetMatch", ctx, "") }
  public override func getMatch(_ ctx: Context) { loghook("GetMatch", ctx, "") }
  public override func prePoint(_ ctx: Context) { loghook("PrePoint", ctx, "") }
  public override func preSpec(_ ctx: Context) { loghook("PreSpec", ctx, "") }
  public override func preRequest(_ ctx: Context) { loghook("PreRequest", ctx, "") }
  public override func preResponse(_ ctx: Context) { loghook("PreResponse", ctx, "") }
  public override func preResult(_ ctx: Context) { loghook("PreResult", ctx, "") }

  private func loghook(_ hook: String, _ ctx: Context, _ levelIn: String) {
    guard let logger = logger else { return }

    var level = levelIn
    if level == "" { level = "info" }

    let attrs = VMap()
    attrs.entries["hook"] = .string(hook)
    if let op = ctx.op { attrs.entries["op"] = .string(op.name) }
    if let spec = ctx.spec { attrs.entries["spec"] = .string(spec.method + " " + spec.path) }

    logger(level, "hook", attrs)
  }
}
