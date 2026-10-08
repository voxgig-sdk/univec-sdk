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

  // The client's auth.name option, when set, replaces the name the API declares.
  private def authName(options: Object): String =
    Struct.getpath(options, java.util.List.of("auth", "name")) match {
      case s: String if "" != s => s.toLowerCase(java.util.Locale.ROOT)
      case _ => CRED_NAME
    }

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

    val name = authName(options)

    // A credential left under the declared name would travel beside the renamed one.
    if (name != CRED_NAME) {
      headers.remove(CRED_NAME)
    }

    val apikey = Struct.getprop(options, OPTION_APIKEY, NOT_FOUND)

    var skip = false
    if (apikey == null) skip = true
    else apikey match {
      case s: String if NOT_FOUND == s || "" == s => skip = true
      case _ =>
    }

    if (skip) {
      headers.remove(name)
    } else {
      var authPrefix = ""
      Struct.getpath(options, java.util.List.of("auth", "prefix")) match { case s: String => authPrefix = s; case _ => }
      val apikeyVal = apikey match { case s: String => s; case _ => "" }
      // A raw credential (empty prefix, e.g. an apiKey scheme) must go in
      // as-is; only a non-empty prefix (Bearer/Basic/OAuth) is space-joined.
      if ("" == authPrefix) headers.put(name, apikeyVal)
      else headers.put(name, authPrefix + " " + apikeyVal)
    }

    spec
  }
}
