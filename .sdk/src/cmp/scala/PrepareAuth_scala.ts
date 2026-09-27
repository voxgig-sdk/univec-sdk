
import {
  Content,
  File,
  Folder,
  cmp,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
  resolveAuthPrefix,
} from '@voxgig/sdkgen'


import { scalaPackage } from './utility_scala'


const PrepareAuth = cmp(async function PrepareAuth(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const where = resolveAuthIn(model)

  const resolved = resolveAuthName(model)
  const name = 'header' === where ? resolved.toLowerCase() : resolved

  const basic = isHttpBasicAuth(model)

  const prefix = resolveAuthPrefix(model)

  const active = !isAuthSuppressed(model)

  const scalapackage = scalaPackage(model)

  Folder({ name: 'utility' }, () => {
    File({ name: 'PrepareAuth.' + target.ext }, () => {
      Content(render({ scalapackage, active, where, name, prefix, basic }))
    })
  })
})


type AuthSpec = {
  scalapackage: string
  active: boolean
  where: string
  name: string
  prefix: string
  basic: boolean
}


function render(spec: AuthSpec): string {
  const head = `package ${spec.scalapackage}.utility

`

  if (!spec.active) {
    return head + `import ${spec.scalapackage}.core.{Context, Spec}

// This SDK is configured with authentication off
// (main.kit.config.auth.active: false), so there is no credential to
// place. The object stays in the pipeline because Register binds
// prepareAuth unconditionally and MakeSpec calls it on every request.
object PrepareAuth {

  def prepareAuth(ctx: Context): Spec = {
    val spec = ctx.spec
    if (spec == null) throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")

    spec
  }
}
`
  }

  if ('query' === spec.where) return renderQuery(spec, head)
  if ('cookie' === spec.where) return renderCookie(spec, head)

  return renderHeader(spec, head)
}


function renderHeader(spec: AuthSpec, head: string): string {
  return head + `${spec.basic ? `import java.nio.charset.StandardCharsets
import java.util.Base64

` : ''}import ${spec.scalapackage}.core.{Context, Spec}
import ${spec.scalapackage}.utility.struct.Struct

// Places the credential as the \`${spec.name}\` request header.
// GENERATED from the API's security scheme (main.kit.info.security:
// in: header, name: ${spec.name}${spec.basic ? ', http basic' : ''}).
object PrepareAuth {
  val CRED_NAME = "${scalastr(spec.name)}"
  val OPTION_APIKEY = "apikey"
${spec.basic ? `  val OPTION_SECRET = "secret"\n` : ''}  val NOT_FOUND = "__NOTFOUND__"

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
${basicBlock(spec)}
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
`
}


// HTTP Basic is header-only by definition: the scheme is `Authorization:
// Basic base64(user:pass)`. It cannot be expressed as a query parameter or
// a cookie, so renderQuery and renderCookie never call this - and it is
// emitted only when the model says the scheme IS basic, so an ordinary
// bearer SDK carries no dead code and regenerates unchanged.
function basicBlock(spec: AuthSpec): string {
  if (!spec.basic) return ''

  return `
    // True HTTP Basic Auth needs TWO credentials, base64-joined - a single
    // token in the header (the branch below) can never authenticate against
    // an API that actually checks \`Authorization: Basic base64(user:pass)\`.
    if (java.lang.Boolean.TRUE == Struct.getpath(options, java.util.List.of("auth", "basic"))) {
      val secret = Struct.getprop(options, OPTION_SECRET, NOT_FOUND)
      val noApikey = apikey == null || (apikey match { case s: String => NOT_FOUND == s || "" == s; case _ => false })
      val noSecret = secret == null || (secret match { case s: String => NOT_FOUND == s || "" == s; case _ => false })

      if (noApikey || noSecret) {
        headers.remove(CRED_NAME)
      } else {
        var basicPrefix = ""
        Struct.getpath(options, java.util.List.of("auth", "prefix")) match { case s: String => basicPrefix = s; case _ => }
        val b64 = Base64.getEncoder.encodeToString(
          ((apikey match { case s: String => s; case _ => "" }) + ":" +
            (secret match { case s: String => s; case _ => "" })).getBytes(StandardCharsets.UTF_8))
        if ("" == basicPrefix) headers.put(CRED_NAME, b64)
        else headers.put(CRED_NAME, basicPrefix + " " + b64)
      }

      return spec
    }
`
}


function renderQuery(spec: AuthSpec, head: string): string {
  return head + `import ${spec.scalapackage}.core.{Context, Spec}
import ${spec.scalapackage}.utility.struct.Struct

// Places the credential as the \`${spec.name}\` query parameter.
// GENERATED from the API's security scheme (main.kit.info.security:
// in: query, name: ${spec.name}).
object PrepareAuth {
  val CRED_NAME = "${scalastr(spec.name)}"
  val OPTION_APIKEY = "apikey"
  val NOT_FOUND = "__NOTFOUND__"

  def prepareAuth(ctx: Context): Spec = {
    val spec = ctx.spec
    if (spec == null) throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")

    val query = spec.query
    val options = ctx.client.optionsMap()

    // Public APIs that need no auth omit the options.auth block entirely.
    if (options.get("auth") == null) {
      query.remove(CRED_NAME)
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
      query.remove(CRED_NAME)
    } else {
      val apikeyVal = apikey match { case s: String => s; case _ => "" }
      // NO PREFIX IN A QUERY STRING. \`?${spec.name}=Bearer%20abc\` is not a
      // thing any API reads: the prefix is a header convention, so the
      // options auth.prefix is dropped here deliberately rather than
      // silently concatenated.
      query.put(CRED_NAME, apikeyVal)
    }

    spec
  }
}
`
}


function renderCookie(spec: AuthSpec, head: string): string {
  return head + `import java.util.{Map => JMap}

import ${spec.scalapackage}.core.{Context, Spec}
import ${spec.scalapackage}.utility.struct.Struct

// Places the credential as the \`${spec.name}\` cookie.
// GENERATED from the API's security scheme (main.kit.info.security:
// in: cookie, name: ${spec.name}).
object PrepareAuth {
  val COOKIE_HEADER = "cookie"
  val CRED_NAME = "${scalastr(spec.name)}"
  val OPTION_APIKEY = "apikey"
  val NOT_FOUND = "__NOTFOUND__"

  // The cookie header minus our own pair, every other cookie untouched.
  private def without(headers: JMap[String, Object]): String = {
    val existing = headers.get(COOKIE_HEADER) match { case s: String => s; case _ => "" }
    if ("" == existing) return ""

    val kept = existing.split(";").map(_.trim).filter { piece =>
      "" != piece && CRED_NAME != piece && !piece.startsWith(CRED_NAME + "=")
    }
    kept.mkString("; ")
  }

  // Set (a value) or remove (null) our pair, leaving the rest in place.
  private def place(headers: JMap[String, Object], value: String): Unit = {
    val rest = without(headers)

    if (value == null) {
      if ("" == rest) headers.remove(COOKIE_HEADER)
      else headers.put(COOKIE_HEADER, rest)
      return
    }

    val pair = CRED_NAME + "=" + value
    if ("" == rest) headers.put(COOKIE_HEADER, pair)
    else headers.put(COOKIE_HEADER, rest + "; " + pair)
  }

  def prepareAuth(ctx: Context): Spec = {
    val spec = ctx.spec
    if (spec == null) throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")

    val headers = spec.headers
    val options = ctx.client.optionsMap()

    // Public APIs that need no auth omit the options.auth block entirely.
    if (options.get("auth") == null) {
      place(headers, null)
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
      place(headers, null)
    } else {
      val apikeyVal = apikey match { case s: String => s; case _ => "" }
      // NO PREFIX IN A COOKIE either - a cookie carries a bare
      // \`name=value\` pair, not a header's scheme-prefixed credential.
      place(headers, apikeyVal)
    }

    spec
  }
}
`
}


function scalastr(s: string): string {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}


export {
  PrepareAuth
}
