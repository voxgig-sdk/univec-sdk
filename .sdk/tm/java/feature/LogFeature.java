package JAVAPACKAGE.feature;

import java.util.Map;
import java.util.logging.Level;
import java.util.logging.Logger;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;

/** Hook logging via java.util.logging (JDK built-in; zero dependencies). */
public class LogFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;
  private Logger logger;

  public LogFeature() {
    super("log", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;

    Object active = options.get("active");
    if (active instanceof Boolean) {
      this.active = (Boolean) active;
    }

    if (this.active) {
      if (options.get("logger") instanceof Logger) {
        this.logger = (Logger) options.get("logger");
      }
      else {
        Level level = Level.INFO;
        Object lvl = options.get("level");
        if ("debug".equals(lvl)) {
          level = Level.FINE;
        }
        else if ("warn".equals(lvl)) {
          level = Level.WARNING;
        }
        else if ("error".equals(lvl)) {
          level = Level.SEVERE;
        }

        this.logger = Logger.getLogger("UnivecSDK.log");
        this.logger.setLevel(level);
      }
    }
  }

  @Override
  public void postConstruct(Context ctx) {
    loghook("PostConstruct", ctx, "");
  }

  @Override
  public void postConstructEntity(Context ctx) {
    loghook("PostConstructEntity", ctx, "");
  }

  @Override
  public void setData(Context ctx) {
    loghook("SetData", ctx, "");
  }

  @Override
  public void getData(Context ctx) {
    loghook("GetData", ctx, "");
  }

  @Override
  public void setMatch(Context ctx) {
    loghook("SetMatch", ctx, "");
  }

  @Override
  public void getMatch(Context ctx) {
    loghook("GetMatch", ctx, "");
  }

  @Override
  public void prePoint(Context ctx) {
    loghook("PrePoint", ctx, "");
  }

  @Override
  public void preSpec(Context ctx) {
    loghook("PreSpec", ctx, "");
  }

  @Override
  public void preRequest(Context ctx) {
    loghook("PreRequest", ctx, "");
  }

  @Override
  public void preResponse(Context ctx) {
    loghook("PreResponse", ctx, "");
  }

  @Override
  public void preResult(Context ctx) {
    loghook("PreResult", ctx, "");
  }

  private void loghook(String hook, Context ctx, String level) {
    if (this.logger == null) {
      return;
    }

    if ("".equals(level)) {
      level = "info";
    }

    StringBuilder msg = new StringBuilder("hook=" + hook);

    if (ctx.op != null) {
      msg.append(" op=").append(ctx.op.name);
    }

    if (ctx.spec != null) {
      msg.append(" spec=").append(ctx.spec.method).append(" ").append(ctx.spec.path);
    }

    switch (level) {
      case "debug":
        this.logger.fine(msg.toString());
        break;
      case "warn":
        this.logger.warning(msg.toString());
        break;
      case "error":
        this.logger.severe(msg.toString());
        break;
      default:
        this.logger.info(msg.toString());
        break;
    }
  }
}
