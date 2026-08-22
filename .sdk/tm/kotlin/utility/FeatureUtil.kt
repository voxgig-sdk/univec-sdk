package KOTLINPACKAGE.utility

import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Feature
import KOTLINPACKAGE.core.FeaturePlacement
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.utility.struct.Struct

// featureAdd appends a feature to the client's feature list. A feature that
// implements FeaturePlacement (every BaseFeature does, via the addOpts
// field) can instead position itself relative to an already-added feature
// via "__before__", "__after__" or "__replace__". The first match wins;
// when no ordering option matches, the feature is appended.
fun featureAdd(ctx: Context, f: Feature) {
  val client = ctx.client!!
  val features = client.features

  var fopts: MutableMap<String, Any?>? = null
  if (f is FeaturePlacement) {
    fopts = f.addOptions()
  }

  if (fopts != null) {
    val before = if (fopts["__before__"] is String) fopts["__before__"] as String else ""
    val after = if (fopts["__after__"] is String) fopts["__after__"] as String else ""
    val replace = if (fopts["__replace__"] is String) fopts["__replace__"] as String else ""

    if ("" != before || "" != after || "" != replace) {
      for (i in features.indices) {
        val name = features[i].name
        if (before == name) {
          features.add(i, f)
          return
        }
        if (after == name) {
          features.add(i + 1, f)
          return
        }
        if (replace == name) {
          features[i] = f
          return
        }
      }
    }
  }

  features.add(f)
}

// featureHook dispatches a named hook to every feature on the client, in
// order. Dispatch is reflective (like the go donor) so features may define
// hooks beyond the Feature interface; the method name is the hook name with
// a lower-cased first letter ("PreRequest" -> preRequest).
fun featureHook(ctx: Context, name: String) {
  val client = ctx.client ?: return
  val features = client.features

  for (f in ArrayList(features)) {
    callFeatureMethod(f, name, ctx)
  }
}

private fun callFeatureMethod(f: Feature, name: String, ctx: Context) {
  if (name.isEmpty()) {
    return
  }
  val mname = name[0].lowercaseChar() + name.substring(1)
  var m = findMethod(f, mname)
  if (m == null) {
    m = findMethod(f, name)
  }
  if (m == null) {
    return
  }
  try {
    m.invoke(f, ctx)
  } catch (e: InvocationTargetException) {
    val cause = e.cause
    if (cause is RuntimeException) {
      throw cause
    }
    if (cause is Error) {
      throw cause
    }
    throw RuntimeException(cause)
  } catch (e: IllegalAccessException) {
    // Non-public hook methods are simply not dispatched.
  }
}

private fun findMethod(f: Feature, mname: String): Method? {
  return try {
    f.javaClass.getMethod(mname, Context::class.java)
  } catch (e: NoSuchMethodException) {
    null
  }
}

fun featureInit(ctx: Context, f: Feature) {
  val fname = f.name
  var fopts: MutableMap<String, Any?> = linkedMapOf()

  val options = ctx.options
  if (options != null) {
    val featureOpts = Helpers.toMapAny(Struct.getprop(options, "feature"))
    if (featureOpts != null) {
      val fo = Helpers.toMapAny(Struct.getprop(featureOpts, fname))
      if (fo != null) {
        fopts = fo
      }
    }
  }

  val active = fopts["active"]
  if (active == true) {
    f.init(ctx, fopts)
  }
}
