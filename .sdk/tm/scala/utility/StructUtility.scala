package SCALAPACKAGE.utility

import java.util.{List => JList, Map => JMap}
import SCALAPACKAGE.utility.struct.Struct

// The struct utility surface exposed via the SDK utility object's `struct`
// member (utility.struct.*). Thin forwarders over the vendored struct
// implementation, mirroring the donor StructUtility shape.
object StructUtility {
  def getprop(v: Object, key: Object): Object = Struct.getprop(v, key)
  def getprop(v: Object, key: Object, alt: Object): Object = Struct.getprop(v, key, alt)
  def getpath(store: Object, path: Object): Object = Struct.getpath(store, path)
  def setpath(store: Object, path: Object, v: Object): Object = Struct.setpath(store, path, v)
  def setprop(parent: Object, key: Object, v: Object): Object = Struct.setprop(parent, key, v)
  def delprop(parent: Object, key: Object): Object = Struct.delprop(parent, key)
  def clone(v: Object): Object = Struct.clone(v)
  def merge(v: Object): Object = Struct.merge(v)
  def items(v: Object): JList[JList[Object]] = Struct.items(v)
  def keysof(v: Object): JList[String] = Struct.keysof(v)
  def isnode(v: Object): Boolean = Struct.isnode(v)
  def ismap(v: Object): Boolean = Struct.ismap(v)
  def islist(v: Object): Boolean = Struct.islist(v)
  def isempty(v: Object): Boolean = Struct.isempty(v)
  def iskey(v: Object): Boolean = Struct.iskey(v)
  def stringify(v: Object): String = Struct.stringify(v)
  def jsonify(v: Object): String = Struct.jsonify(v)
  def escre(v: Object): String = Struct.escre(v)
  def escurl(v: Object): String = Struct.escurl(v)
}
