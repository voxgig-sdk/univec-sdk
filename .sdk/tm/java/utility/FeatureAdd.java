package JAVAPACKAGE.utility;

import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Feature;
import JAVAPACKAGE.core.FeaturePlacement;
import JAVAPACKAGE.core.SdkClient;

// featureAdd appends a feature to the client's feature list. A feature
// that implements FeaturePlacement (every BaseFeature does, via the
// addOpts field) can instead position itself relative to an already-added
// feature via "__before__", "__after__" or "__replace__" naming that
// feature — mirroring the ts featureAdd. The first match wins; when no
// ordering option matches, the feature is appended.
final class FeatureAdd {

  private FeatureAdd() {}

  static void featureAdd(Context ctx, Feature f) {
    SdkClient client = ctx.client;
    List<Feature> features = client.features;

    Map<String, Object> fopts = null;
    if (f instanceof FeaturePlacement) {
      fopts = ((FeaturePlacement) f).addOptions();
    }

    if (fopts != null) {
      String before = fopts.get("__before__") instanceof String
          ? (String) fopts.get("__before__") : "";
      String after = fopts.get("__after__") instanceof String
          ? (String) fopts.get("__after__") : "";
      String replace = fopts.get("__replace__") instanceof String
          ? (String) fopts.get("__replace__") : "";

      if (!"".equals(before) || !"".equals(after) || !"".equals(replace)) {
        for (int i = 0; i < features.size(); i++) {
          String name = features.get(i).getName();
          if (before.equals(name)) {
            features.add(i, f);
            return;
          }
          if (after.equals(name)) {
            features.add(i + 1, f);
            return;
          }
          if (replace.equals(name)) {
            features.set(i, f);
            return;
          }
        }
      }
    }

    features.add(f);
  }
}
