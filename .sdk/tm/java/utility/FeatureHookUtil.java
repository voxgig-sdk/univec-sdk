package JAVAPACKAGE.utility;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Feature;
import JAVAPACKAGE.core.SdkClient;

// featureHook dispatches a named hook to every feature on the client, in
// order. Dispatch is reflective (like the go donor) so features may define
// hooks beyond the Feature interface; the Java method name is the hook name
// with a lower-cased first letter ("PreRequest" -> preRequest).
final class FeatureHookUtil {

  private FeatureHookUtil() {}

  static void featureHook(Context ctx, String name) {
    SdkClient client = ctx.client;
    if (client == null) {
      return;
    }
    List<Feature> features = client.features;
    if (features == null) {
      return;
    }

    for (Feature f : new ArrayList<>(features)) {
      callFeatureMethod(f, name, ctx);
    }
  }

  static void callFeatureMethod(Feature f, String name, Context ctx) {
    if (name == null || name.isEmpty()) {
      return;
    }
    String mname = Character.toLowerCase(name.charAt(0)) + name.substring(1);
    Method m = findMethod(f, mname);
    if (m == null) {
      m = findMethod(f, name);
    }
    if (m == null) {
      return;
    }
    try {
      m.invoke(f, ctx);
    }
    catch (java.lang.reflect.InvocationTargetException e) {
      Throwable cause = e.getCause();
      if (cause instanceof RuntimeException) {
        throw (RuntimeException) cause;
      }
      if (cause instanceof Error) {
        throw (Error) cause;
      }
      throw new RuntimeException(cause);
    }
    catch (IllegalAccessException e) {
      // Non-public hook methods are simply not dispatched.
    }
  }

  private static Method findMethod(Feature f, String mname) {
    try {
      return f.getClass().getMethod(mname, Context.class);
    }
    catch (NoSuchMethodException e) {
      return null;
    }
  }
}
