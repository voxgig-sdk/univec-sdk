package JAVAPACKAGE.core;

import java.util.Map;

/**
 * Optional capability: a feature exposing add-time placement options
 * ("__before__", "__after__", "__replace__") read by the featureAdd
 * utility. Every BaseFeature implements this via its addOpts field.
 */
public interface FeaturePlacement {

  Map<String, Object> addOptions();
}
