package KOTLINPACKAGE.feature

import java.util.logging.Level
import java.util.logging.Logger

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.SdkClient

/** Hook logging via java.util.logging (JDK built-in; zero dependencies). */
class LogFeature : BaseFeature("log", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null
  private var logger: Logger? = null

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options

    val a = options["active"]
    if (a is Boolean) {
      this.active = a
    }

    if (this.active) {
      val lg = options["logger"]
      if (lg is Logger) {
        this.logger = lg
      } else {
        var level = Level.INFO
        val lvl = options["level"]
        if ("debug" == lvl) {
          level = Level.FINE
        } else if ("warn" == lvl) {
          level = Level.WARNING
        } else if ("error" == lvl) {
          level = Level.SEVERE
        }

        this.logger = Logger.getLogger("UnivecSDK.log")
        this.logger!!.level = level
      }
    }
  }

  override fun postConstruct(ctx: Context) = loghook("PostConstruct", ctx, "")

  override fun postConstructEntity(ctx: Context) = loghook("PostConstructEntity", ctx, "")

  override fun setData(ctx: Context) = loghook("SetData", ctx, "")

  override fun getData(ctx: Context) = loghook("GetData", ctx, "")

  override fun setMatch(ctx: Context) = loghook("SetMatch", ctx, "")

  override fun getMatch(ctx: Context) = loghook("GetMatch", ctx, "")

  override fun prePoint(ctx: Context) = loghook("PrePoint", ctx, "")

  override fun preSpec(ctx: Context) = loghook("PreSpec", ctx, "")

  override fun preRequest(ctx: Context) = loghook("PreRequest", ctx, "")

  override fun preResponse(ctx: Context) = loghook("PreResponse", ctx, "")

  override fun preResult(ctx: Context) = loghook("PreResult", ctx, "")

  private fun loghook(hook: String, ctx: Context, levelIn: String) {
    val logger = this.logger ?: return

    var level = levelIn
    if ("" == level) {
      level = "info"
    }

    val msg = StringBuilder("hook=$hook")

    msg.append(" op=").append(ctx.op.name)

    val spec = ctx.spec
    if (spec != null) {
      msg.append(" spec=").append(spec.method).append(" ").append(spec.path)
    }

    when (level) {
      "debug" -> logger.fine(msg.toString())
      "warn" -> logger.warning(msg.toString())
      "error" -> logger.severe(msg.toString())
      else -> logger.info(msg.toString())
    }
  }
}
