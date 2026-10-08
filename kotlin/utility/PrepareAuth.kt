package voxgig.univecsdk.utility

import voxgig.univecsdk.core.Context
import voxgig.univecsdk.core.Spec
import voxgig.univecsdk.utility.struct.Struct

private const val HEADER_AUTH = "authorization"
private const val OPTION_APIKEY = "apikey"
private const val NOT_FOUND = "__NOTFOUND__"

// The client's auth.name option, when set, replaces the name the API declares.
private fun prepareAuthName(options: Any?): String {
  val name = Struct.getpath(options, listOf("auth", "name"))
  return if (name is String && "" != name) name.lowercase() else HEADER_AUTH
}

fun prepareAuth(ctx: Context): Spec {
  val spec = ctx.spec
    ?: throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")

  val headers = spec.headers
  val options = ctx.client!!.optionsMap()

  // Public APIs that need no auth omit the options.auth block entirely.
  if (options["auth"] == null) {
    headers.remove(HEADER_AUTH)
    return spec
  }

  val name = prepareAuthName(options)

  // A credential left under the declared name would travel beside the renamed one.
  if (name != HEADER_AUTH) {
    headers.remove(HEADER_AUTH)
  }

  val apikey = Struct.getprop(options, OPTION_APIKEY, NOT_FOUND)

  var skip = false
  if (apikey == null) {
    skip = true
  } else if (apikey is String && (NOT_FOUND == apikey || "" == apikey)) {
    skip = true
  }

  if (skip) {
    headers.remove(name)
  } else {
    var authPrefix = ""
    val ap = Struct.getpath(options, listOf("auth", "prefix"))
    if (ap is String) {
      authPrefix = ap
    }
    val apikeyVal = if (apikey is String) apikey else ""
    // Empty prefix (raw apiKey credential) must not add a leading space.
    if ("" == authPrefix) {
      headers[name] = apikeyVal
    } else {
      headers[name] = "$authPrefix $apikeyVal"
    }
  }

  return spec
}
