package SCALAPACKAGE.feature

import java.util.{Map => JMap}
import SCALAPACKAGE.core.{Context, Feature}

// No-op base feature; concrete features override the hooks they need.
class BaseFeature(var name: String, var version: String, var active: Boolean) extends Feature {

  // addOpts positions this feature when added via the client `extend`
  // option: "__before__", "__after__" or "__replace__" name an already-added
  // feature (mirrors the ts feature `_options`).
  var addOpts: JMap[String, Object] = null

  def this() = this("base", "0.0.1", true)

  override def addOptions(): JMap[String, Object] = addOpts

  def getVersion(): String = version
  def getName(): String = name
  def getActive(): Boolean = active
}
