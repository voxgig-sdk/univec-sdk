package SCALAPACKAGE.utility

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core._
import SCALAPACKAGE.utility.struct.Struct

// featureAdd appends a feature to the client's feature list. A feature that
// exposes add-time placement options can instead position itself relative to
// an already-added feature via "__before__"/"__after__"/"__replace__".
object FeatureAdd {
  def featureAdd(ctx: Context, f: Feature): Unit = {
    val client = ctx.client
    val features = client.features

    val fopts = f.addOptions()

    if (fopts != null) {
      val before = fopts.get("__before__") match { case s: String => s; case _ => "" }
      val after = fopts.get("__after__") match { case s: String => s; case _ => "" }
      val replace = fopts.get("__replace__") match { case s: String => s; case _ => "" }

      if ("" != before || "" != after || "" != replace) {
        var i = 0
        while (i < features.size()) {
          val name = features.get(i).getName()
          if (before == name) { features.add(i, f); return }
          if (after == name) { features.add(i + 1, f); return }
          if (replace == name) { features.set(i, f); return }
          i += 1
        }
      }
    }

    features.add(f)
  }
}

object FeatureInit {
  def featureInit(ctx: Context, f: Feature): Unit = {
    val fname = f.getName()
    var fopts: JMap[String, Object] = new LinkedHashMap[String, Object]()

    if (ctx.options != null) {
      val featureOpts = Helpers.toMapAny(Struct.getprop(ctx.options, "feature"))
      if (featureOpts != null) {
        val fo = Helpers.toMapAny(Struct.getprop(featureOpts, fname))
        if (fo != null) fopts = fo
      }
    }

    if (java.lang.Boolean.TRUE == fopts.get("active")) f.init(ctx, fopts)
  }
}

// featureHook dispatches a named hook to every feature on the client, in
// order (via Feature.hook — no reflection).
object FeatureHookUtil {
  def featureHook(ctx: Context, name: String): Unit = {
    val client = ctx.client
    if (client == null) return
    val features = client.features
    if (features == null) return
    if (name == null || name.isEmpty) return

    val it = new ArrayList[Feature](features).iterator()
    while (it.hasNext) it.next().hook(name, ctx)
  }
}
