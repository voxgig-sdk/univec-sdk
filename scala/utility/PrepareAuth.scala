package voxgig.univecsdk.utility

import voxgig.univecsdk.core.{Context, Spec}
import voxgig.univecsdk.utility.struct.Struct

// Places the credential as the `authorization` request header.
// GENERATED from the API's security scheme (main.kit.info.security:
// in: header, name: authorization).
object PrepareAuth {
  val CRED_NAME = "authorization"
  val OPTION_APIKEY = "apikey"
  val NOT_FOUND = "__NOTFOUND__"

  def prepareAuth(ctx: Context): Spec = {
    val spec = ctx.spec
    if (spec == null) throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")

    val headers = spec.headers
    val options = ctx.client.optionsMap()

    // Public APIs that need no auth omit the options.auth block entirely.
    if (options.get("auth") == null) {
      headers.remove(CRED_NAME)
      return spec
    }

    val apikey = Struct.getprop(options, OPTION_APIKEY, NOT_FOUND)

    var skip = false
    if (apikey == null) skip = true
    else apikey match {
      case s: String if NOT_FOUND == s || "" == s => skip = true
      case _ =>
    }

    if (skip) {
      headers.remove(CRED_NAME)
    } else {
      var authPrefix = ""
      Struct.getpath(options, java.util.List.of("auth", "prefix")) match { case s: String => authPrefix = s; case _ => }
      val apikeyVal = apikey match { case s: String => s; case _ => "" }
      // A raw credential (empty prefix, e.g. an apiKey scheme) must go in
      // as-is; only a non-empty prefix (Bearer/Basic/OAuth) is space-joined.
      if ("" == authPrefix) headers.put(CRED_NAME, apikeyVal)
      else headers.put(CRED_NAME, authPrefix + " " + apikeyVal)
    }

    spec
  }
}
