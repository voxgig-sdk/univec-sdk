package JAVAPACKAGE.core;

import java.util.Map;

/**
 * A Univec SDK feature. Hook methods are dispatched by name via the
 * featureHook utility (reflectively, so features may also define extra
 * hooks beyond this interface).
 */
public interface Feature {

  String getVersion();

  String getName();

  boolean getActive();

  void init(Context ctx, Map<String, Object> options);

  void postConstruct(Context ctx);

  void postConstructEntity(Context ctx);

  void setData(Context ctx);

  void getData(Context ctx);

  void getMatch(Context ctx);

  void setMatch(Context ctx);

  void prePoint(Context ctx);

  void preSpec(Context ctx);

  void preRequest(Context ctx);

  void preResponse(Context ctx);

  void preResult(Context ctx);

  void preDone(Context ctx);

  void preUnexpected(Context ctx);
}
