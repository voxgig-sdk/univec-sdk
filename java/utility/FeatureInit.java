package voxgig.univecsdk.utility;

import java.util.LinkedHashMap;
import java.util.Map;

import voxgig.univecsdk.core.Context;
import voxgig.univecsdk.core.Feature;
import voxgig.univecsdk.core.Helpers;
import voxgig.univecsdk.utility.struct.Struct;

final class FeatureInit {

  private FeatureInit() {}

  static void featureInit(Context ctx, Feature f) {
    String fname = f.getName();
    Map<String, Object> fopts = new LinkedHashMap<>();

    if (ctx.options != null) {
      Map<String, Object> featureOpts =
          Helpers.toMapAny(Struct.getprop(ctx.options, "feature"));
      if (featureOpts != null) {
        Map<String, Object> fo = Helpers.toMapAny(Struct.getprop(featureOpts, fname));
        if (fo != null) {
          fopts = fo;
        }
      }
    }

    Object active = fopts.get("active");
    if (Boolean.TRUE.equals(active)) {
      f.init(ctx, fopts);
    }
  }
}
