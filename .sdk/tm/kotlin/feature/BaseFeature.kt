package KOTLINPACKAGE.feature

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Feature
import KOTLINPACKAGE.core.FeaturePlacement

/** No-op base feature; concrete features override the hooks they need. */
open class BaseFeature() : Feature, FeaturePlacement {

  override var version: String = "0.0.1"
  override var name: String = "base"
  override var active: Boolean = true

  // addOpts positions this feature when added via the client `extend`
  // option: "__before__", "__after__" or "__replace__" name an
  // already-added feature (mirrors the ts feature `_options`).
  var addOpts: MutableMap<String, Any?>? = null

  constructor(name: String, version: String, active: Boolean) : this() {
    this.name = name
    this.version = version
    this.active = active
  }

  // addOptions is read by the featureAdd utility to place this feature.
  override fun addOptions(): MutableMap<String, Any?>? {
    return this.addOpts
  }

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {}

  override fun postConstruct(ctx: Context) {}

  override fun postConstructEntity(ctx: Context) {}

  override fun setData(ctx: Context) {}

  override fun getData(ctx: Context) {}

  override fun getMatch(ctx: Context) {}

  override fun setMatch(ctx: Context) {}

  override fun prePoint(ctx: Context) {}

  override fun preSpec(ctx: Context) {}

  override fun preRequest(ctx: Context) {}

  override fun preResponse(ctx: Context) {}

  override fun preResult(ctx: Context) {}

  override fun preDone(ctx: Context) {}

  override fun preUnexpected(ctx: Context) {}
}
