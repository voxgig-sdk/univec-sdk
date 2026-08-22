package voxgig.univecsdk.feature

import java.util.{Map => JMap}
import java.util.logging.{Level, Logger}
import voxgig.univecsdk.core.{Context, SdkClient}

// Hook logging via java.util.logging (JDK built-in; zero dependencies).
class LogFeature extends BaseFeature("log", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null
  private var logger: Logger = null

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options

    options.get("active") match { case b: java.lang.Boolean => this.active = b.booleanValue(); case _ => }

    if (this.active) {
      options.get("logger") match {
        case l: Logger => this.logger = l
        case _ =>
          var level = Level.INFO
          options.get("level") match {
            case "debug" => level = Level.FINE
            case "warn" => level = Level.WARNING
            case "error" => level = Level.SEVERE
            case _ =>
          }
          this.logger = Logger.getLogger("UnivecSDK.log")
          this.logger.setLevel(level)
      }
    }
  }

  override def postConstruct(ctx: Context): Unit = loghook("PostConstruct", ctx, "")
  override def postConstructEntity(ctx: Context): Unit = loghook("PostConstructEntity", ctx, "")
  override def setData(ctx: Context): Unit = loghook("SetData", ctx, "")
  override def getData(ctx: Context): Unit = loghook("GetData", ctx, "")
  override def setMatch(ctx: Context): Unit = loghook("SetMatch", ctx, "")
  override def getMatch(ctx: Context): Unit = loghook("GetMatch", ctx, "")
  override def prePoint(ctx: Context): Unit = loghook("PrePoint", ctx, "")
  override def preSpec(ctx: Context): Unit = loghook("PreSpec", ctx, "")
  override def preRequest(ctx: Context): Unit = loghook("PreRequest", ctx, "")
  override def preResponse(ctx: Context): Unit = loghook("PreResponse", ctx, "")
  override def preResult(ctx: Context): Unit = loghook("PreResult", ctx, "")

  private def loghook(hook: String, ctx: Context, level0: String): Unit = {
    if (this.logger == null) return
    val level = if ("" == level0) "info" else level0

    val msg = new StringBuilder("hook=" + hook)
    if (ctx.op != null) msg.append(" op=").append(ctx.op.name)
    if (ctx.spec != null) msg.append(" spec=").append(ctx.spec.method).append(" ").append(ctx.spec.path)

    level match {
      case "debug" => this.logger.fine(msg.toString)
      case "warn" => this.logger.warning(msg.toString)
      case "error" => this.logger.severe(msg.toString)
      case _ => this.logger.info(msg.toString)
    }
  }
}
