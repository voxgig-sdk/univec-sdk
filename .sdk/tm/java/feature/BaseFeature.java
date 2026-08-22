package JAVAPACKAGE.feature;

import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Feature;
import JAVAPACKAGE.core.FeaturePlacement;

/** No-op base feature; concrete features override the hooks they need. */
public class BaseFeature implements Feature, FeaturePlacement {

  public String version = "0.0.1";
  public String name = "base";
  public boolean active = true;

  // addOpts positions this feature when added via the client `extend`
  // option: "__before__", "__after__" or "__replace__" name an
  // already-added feature (mirrors the ts feature `_options`).
  public Map<String, Object> addOpts;

  public BaseFeature() {}

  public BaseFeature(String name, String version, boolean active) {
    this.name = name;
    this.version = version;
    this.active = active;
  }

  // addOptions is read by the featureAdd utility to place this feature.
  @Override
  public Map<String, Object> addOptions() {
    return this.addOpts;
  }

  @Override
  public String getVersion() {
    return this.version;
  }

  @Override
  public String getName() {
    return this.name;
  }

  @Override
  public boolean getActive() {
    return this.active;
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {}

  @Override
  public void postConstruct(Context ctx) {}

  @Override
  public void postConstructEntity(Context ctx) {}

  @Override
  public void setData(Context ctx) {}

  @Override
  public void getData(Context ctx) {}

  @Override
  public void getMatch(Context ctx) {}

  @Override
  public void setMatch(Context ctx) {}

  @Override
  public void prePoint(Context ctx) {}

  @Override
  public void preSpec(Context ctx) {}

  @Override
  public void preRequest(Context ctx) {}

  @Override
  public void preResponse(Context ctx) {}

  @Override
  public void preResult(Context ctx) {}

  @Override
  public void preDone(Context ctx) {}

  @Override
  public void preUnexpected(Context ctx) {}
}
