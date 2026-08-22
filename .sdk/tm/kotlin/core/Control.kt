package KOTLINPACKAGE.core

/** Per-call control state: throw behaviour, explain capture, actor, paging. */
class Control {

  // Tri-state: null (default: throw), true, or false (return fallback data).
  var throwing: Boolean? = null

  var err: RuntimeException? = null

  var explain: MutableMap<String, Any?>? = null

  var actor: String = ""

  var paging: MutableMap<String, Any?>? = null

  // Outbound streaming marker: the entity `stream` method sets this to the
  // caller-supplied streamable payload so the request builder / transport can
  // stream it as the request body.
  var streamOut: Any? = null
}
