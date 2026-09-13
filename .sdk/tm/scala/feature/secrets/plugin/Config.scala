// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (scala/src/Config.scala)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package voxgig.plugin

/** The declarative document (section 9): normalization, and the ten-level
  * precedence ladder.
  *
  * TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
  *
  * `normalizeConfig` normalizes STRUCTURE and ENTRY KEYS. It does not merge
  * options, and cannot: section 9.4 makes merge behaviour a property of the
  * definition's option SHAPE, which normalization has never seen. A normalizer
  * that flattened the option layers would make `$MERGE: append` unimplementable
  * at load time, because the layers it must concatenate would already be
  * collapsed.
  *
  * `resolveOptions` applies the ladder, and it is the only place that knows the
  * shape.
  */
object Config {

  private val mergeWords = List("replace", "append")

  private final case class Entries(map: Map[String, Value], order: List[String])

  /** Both document forms reduce to {ref -> entry} plus the order the form
    * implies: array POSITION for the array form, sorted refs for the map form.
    */
  private def entriesOf(src: Value): Entries = src match {
    case VNull => Entries(Map.empty, Nil)

    case VList(items) =>
      val refs = items.map(item => Refs.canonRef(item.at("ref")))
      Entries(refs.zip(items).toMap, refs)

    case _ =>
      // Map-form refs arrive as KEYS, through a different path than an array
      // element's `ref` field - and must canonicalize the same way.
      val m = src.keys.map(k => Refs.canonRef(VStr(k)) -> src.at(k)).toMap
      // Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
      // sort identically under all three, so only mixed input discriminates:
      // '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. Scala's
      // `String` ordering is `compareTo`, which is exactly that.
      Entries(m, m.keys.toList.sorted)
  }

  private def checkReserved(ref: String, reserved: Value): Unit = {
    if (reserved.items.contains(VStr(Refs.refName(VStr(ref))))) {
      Types.fail(
        "plugin_ref_reserved", "ref is reserved by the host: " + ref,
        Map("ref" -> VStr(ref))
      )
    }
  }

  /** PRESENCE decides, not truthiness and not null. A JSON `null` is a present
    * value in JavaScript (`undefined !== null`), so it must be one here.
    */
  private def pick(src: Option[Value], key: String, dflt: Value): Value = src match {
    case Some(s) if s.has(key) => s.at(key)
    case _                     => dflt
  }

  def normalizeConfig(input: Value): Value = {
    val doc = input.at("doc")
    val keys = input.at("keys")
    val ikey = keys.at("instance").asString.getOrElse("instance")
    val dkey = keys.at("default").asString.getOrElse("default")
    val reserved = input.at("reserved")
    val profile = input.at("profile")

    // The rename is applied at TWO PLACES AND NO OTHERS: the document root, and
    // every profile.<name> overlay root (section 9.1). A rename applied only at
    // the root would leave `profile.prod.sdk` untranslated and silently drop
    // every environment override the host depends on. Recursing further would
    // be worse: option data is the definition's.
    val basedef = doc.at(dkey)
    val overlay = profile.asString.map(doc.at("profile").at(_)).filter(_.isMap)
      .getOrElse(VMap(Map.empty))
    val overdef = overlay.at(dkey)

    val base = entriesOf(doc.at(ikey))
    val over = entriesOf(overlay.at(ikey))

    List(base.map.keys.toList.sorted, over.map.keys.toList.sorted,
      basedef.keys, overdef.keys)
      .foreach(_.foreach(ref => checkReserved(ref, reserved)))

    // A PARTIAL ARRAY IS NOT A FILTER (section 9.1). sdkgen learned this the
    // hard way: deriving order from a partial array silently dropped
    // config-activated features. Refs in the base but absent from the overlay
    // still load, in sorted position AFTER the listed ones. A profile may also
    // INTRODUCE a ref the base never declared. The remainder keeps the BASE's
    // own order.
    val order = (over.order ++ base.order).distinct

    val instance = order.zipWithIndex.map { case (ref, i) =>
      val b = base.map.get(ref)
      val o = over.map.get(ref)

      // MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
      // (section 9.3). A safety rule, not a tidiness one: if the overlay had
      // its defaults filled in before merging it would carry a synthesized
      // active:true and overwrite a base's false - silently re-enabling a
      // deliberately disabled integration in production.
      val block = pick(o, "order", pick(b, "order", VNull))

      // Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
      val nm = Refs.refName(VStr(ref))
      val layers = List(basedef.get(nm), b, overdef.get(nm), o)
        .flatten.filter(_.has("options")).map(_.at("options"))

      val ent = Map[String, Value](
        "pos" -> VNum(i.toDouble),
        "active" -> pick(o, "active", pick(b, "active", VBool(true))),
        "start" -> pick(o, "start", pick(b, "start", VStr("eager"))),
        "optionlayers" -> VList(layers)
      )
      ref -> VMap(if (block.isNull) ent else ent + ("order" -> block))
    }.toMap

    // `default` DECLARES NOTHING (section 9.3). It is a base for every instance
    // of that definition; it does not create one, and an entry for a name with
    // no instances is inert rather than an error - which is what makes a shared
    // library of defaults shippable.
    val defout = basedef.entries ++ overdef.entries

    Value.map(
      "instance" -> VMap(instance),
      "order" -> VList(order.map(VStr.apply)),
      "default" -> VMap(defout)
    )
  }

  /** Section 9.4: N is an integer of at least 1, and everything else is an
    * error.
    *
    * `{"deep": 0}` is rejected DESPITE having an obvious reading, because
    * "replace at this key" already has a spelling and two spellings for one
    * behaviour is the defect class this repo exists to avoid.
    */
  def checkShape(shape: Value): Unit = {
    if (!shape.isMap) return
    shape.keys.foreach { k =>
      val v = shape.at(k)
      if (v.has("$MERGE")) {
        val directive = v.at("$MERGE")
        directive match {
          case VStr(word) if mergeWords.contains(word) => ()
          case VStr(word) =>
            Types.fail(
              "plugin_shape_invalid", "invalid $MERGE directive at " + k + ": " + word,
              Map("key" -> VStr(k), "directive" -> directive)
            )
          case d if d.has("deep") =>
            val n = d.at("deep")
            // `VBool(true)` is a different case class from `VNum`, so the
            // boolean falls out for free here - unlike python, where it does
            // not.
            if (!n.asInt.exists(_ >= 1)) {
              Types.fail(
                "plugin_shape_invalid",
                "invalid $MERGE deep at " + k + ": " + n.json,
                Map("key" -> VStr(k), "directive" -> directive)
              )
            }
          case _ =>
            Types.fail(
              "plugin_shape_invalid",
              "invalid $MERGE directive at " + k + ": " + directive.json,
              Map("key" -> VStr(k), "directive" -> directive)
            )
        }
      }
    }
  }

  /** The shape's non-directive values are the level-1 defaults. */
  private def defaultsOf(shape: Value): Value =
    VMap(shape.keys.filterNot(k => shape.at(k).has("$MERGE"))
      .map(k => k -> shape.at(k)).toMap)

  private def optsOf(src: Value, key: String): Option[Value] = src match {
    case VNull => None
    // The array form is equivalent to the map form (section 9.1).
    case VList(items) =>
      items.find(item => Refs.canonRef(item.at("ref")) == key).flatMap(_.get("options"))
    case _ =>
      src.keys.find(k => Refs.canonRef(VStr(k)) == key).flatMap { k =>
        val entry = src.at(k)
        if (entry.isMap) entry.get("options") else None
      }
  }

  /** Merge N levels below this key, replace below that. */
  private def deepTo(base: Value, over: Value, n: Int): Value = {
    if (n <= 0 || !base.isMap || !over.isMap) return over
    VMap(over.keys.foldLeft(base.entries) { (acc, k) =>
      acc + (k -> deepTo(acc.getOrElse(k, VNull), over.at(k), n - 1))
    })
  }

  /** Merge ONE layer onto the accumulator, honouring the shape's directives.
    * The directive holds at EVERY precedence level, not only between document
    * levels - section 9.4 makes it a property of the shape, which does not know
    * which layer a value arrived from.
    */
  private def mergeOne(base: Value, over: Value, shape: Value): Value = {
    if (over.isNull) return base
    if (!base.isMap || !over.isMap) return over

    VMap(over.keys.foldLeft(base.entries) { (acc, k) =>
      val ov = over.at(k)
      val bv = acc.getOrElse(k, VNull)
      val directive = shape.at(k).at("$MERGE")

      val merged =
        if (directive == VStr("replace")) {
          ov
        } else if (directive == VStr("append")) {
          val bl = if (bv.isList) bv.items else Nil
          val ol = if (ov.isList) ov.items else List(ov)
          VList(bl ++ ol)
        } else if (directive.has("deep")) {
          deepTo(bv, ov, directive.at("deep").asInt.getOrElse(0))
        } else if (bv.isMap && ov.isMap) {
          // Library default: deep for maps, REPLACE for lists. struct.merge is
          // element-wise by index, which for option maps is nearly always wrong
          // - ["a"] over ["x","y","z"] yielding ["a","y","z"] is the defect
          // station hit on secrets.providers.
          mergeOne(bv, ov, VNull)
        } else {
          ov
        }
      acc + (k -> merged)
    })
  }

  def resolveOptions(input: Value): Value = {
    val shape = input.at("shape")
    checkShape(shape)

    val ref = Refs.canonRef(input.at("ref"))
    val name = Refs.refName(VStr(ref))
    val doc = input.at("doc")
    val overlay = input.at("profile").asString.map(doc.at("profile").at(_))
      .filter(_.isMap).getOrElse(VMap(Map.empty))

    // ONE ordered merge, lowest to highest. Levels 3-6 are not two namespaces
    // collapsed separately and composed afterwards: that inverts the rule that
    // PROFILE SPECIFICITY OUTRANKS DEFINITION SPECIFICITY, so a prod
    // per-definition default would lose to a base instance value.
    val layers = List(
      Some(defaultsOf(shape)),                        // 1
      input.get("hostdefaults"),                      // 2
      optsOf(doc.at("default"), name),                // 3
      optsOf(doc.at("instance"), ref),                // 4
      optsOf(overlay.at("default"), name),            // 5
      optsOf(overlay.at("instance"), ref),            // 6
      input.get("env"),                               // 7
      input.get("hostoptions"),                       // 8
      input.get("loadoptions"),                       // 9
      input.get("patch")                              // 10
    )

    layers.flatten.filterNot(_.isNull)
      .foldLeft(VMap(Map.empty): Value)((acc, layer) => mergeOne(acc, layer, shape))
  }
}
