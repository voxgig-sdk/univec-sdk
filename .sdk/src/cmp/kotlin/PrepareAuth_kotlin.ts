
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


import { kotlinPackage } from './utility_kotlin'


const PrepareAuth = cmp(async function PrepareAuth(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const kotlinpackage = kotlinPackage(model)

  const where = resolveAuthIn(model)

  const resolved = resolveAuthName(model)
  const name = 'header' === where ? resolved.toLowerCase() : resolved

  const basic = isHttpBasicAuth(model)

  const prefix = resolveAuthPrefix(model)

  Folder({ name: 'utility' }, () => {
    File({ name: 'PrepareAuth.' + target.ext }, () => {
      Content(render({
        kotlinpackage,
        suppressed: isAuthSuppressed(model),
        where,
        name,
        basic,
        prefix,
      }))
    })
  })
})


type AuthSpec = {
  kotlinpackage: string
  suppressed: boolean
  where: string
  name: string
  basic: boolean
  prefix: string
}


function render(spec: AuthSpec): string {
  if (spec.suppressed) {
    return head(spec) + `import ${spec.kotlinpackage}.core.Context
import ${spec.kotlinpackage}.core.Spec

// This SDK is built with \`config.auth.active: false\`, so there is no
// credential to place. The function stays in the pipeline because Register
// binds it unconditionally and MakeSpecUrl calls it on every request, and a
// missing spec is still the same error it always was.
fun prepareAuth(ctx: Context): Spec {
  return ctx.spec
    ?: throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")
}
`
  }

  if ('query' === spec.where) return renderQuery(spec)
  if ('cookie' === spec.where) return renderCookie(spec)

  return renderHeader(spec)
}


function head(spec: AuthSpec): string {
  return `package ${spec.kotlinpackage}.utility

`
}


const SKIP = `  var skip = false
  if (apikey == null) {
    skip = true
  } else if (apikey is String && (NOT_FOUND == apikey || "" == apikey)) {
    skip = true
  }
`


// HEADER. The body is the deleted \`fun prepareAuth\` from
// tm/kotlin/utility/Prepare.kt, character for character, for a scheme that
// resolves to the defaults (header / Authorization -> "authorization") and
// is not HTTP Basic. Only the constant's VALUE moves with the model, plus
// the Basic block, which is emitted only for a Basic scheme.
function renderHeader(spec: AuthSpec): string {
  const basicBranch = spec.basic

  return head(spec) + (basicBranch ? `import java.util.Base64

` : '') + `import ${spec.kotlinpackage}.core.Context
import ${spec.kotlinpackage}.core.Spec
import ${spec.kotlinpackage}.utility.struct.Struct

private const val HEADER_AUTH = "${ktstr(spec.name)}"
private const val OPTION_APIKEY = "apikey"
` + (basicBranch ? `private const val OPTION_SECRET = "secret"
` : '') + `private const val NOT_FOUND = "__NOTFOUND__"

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

  val apikey = Struct.getprop(options, OPTION_APIKEY, NOT_FOUND)
` + basicBlock(spec) + `
` + SKIP + `
  if (skip) {
    headers.remove(HEADER_AUTH)
  } else {
    var authPrefix = ""
    val ap = Struct.getpath(options, listOf("auth", "prefix"))
    if (ap is String) {
      authPrefix = ap
    }
    val apikeyVal = if (apikey is String) apikey else ""
    // Empty prefix (raw apiKey credential) must not add a leading space.
    if ("" == authPrefix) {
      headers[HEADER_AUTH] = apikeyVal
    } else {
      headers[HEADER_AUTH] = "\$authPrefix \$apikeyVal"
    }
  }

  return spec
}
`
}


function basicBlock(spec: AuthSpec): string {
  if (!spec.basic) return ''

  return `
  // True HTTP Basic Auth needs TWO credentials, base64-joined - a single
  // token in the header (the branch below) can never authenticate against
  // an API that actually checks \`Authorization: Basic base64(user:pass)\`.
  val basicOpt = Struct.getpath(options, listOf("auth", "basic"))
  if (basicOpt is Boolean && basicOpt) {
    val secret = Struct.getprop(options, OPTION_SECRET, NOT_FOUND)
    val noApikey = apikey == null ||
      (apikey is String && (NOT_FOUND == apikey || "" == apikey))
    val noSecret = secret == null ||
      (secret is String && (NOT_FOUND == secret || "" == secret))

    if (noApikey || noSecret) {
      headers.remove(HEADER_AUTH)
    } else {
      var basicPrefix = ""
      val bp = Struct.getpath(options, listOf("auth", "prefix"))
      if (bp is String) {
        basicPrefix = bp
      }
      val b64 = Base64.getEncoder().encodeToString(
        (apikey.toString() + ":" + secret.toString()).toByteArray(Charsets.UTF_8))
      if ("" == basicPrefix) {
        headers[HEADER_AUTH] = b64
      } else {
        headers[HEADER_AUTH] = "\$basicPrefix \$b64"
      }
    }

    return spec
  }
`
}


function renderQuery(spec: AuthSpec): string {
  return head(spec) + `import ${spec.kotlinpackage}.core.Context
import ${spec.kotlinpackage}.core.Spec
import ${spec.kotlinpackage}.utility.struct.Struct

private const val QUERY_AUTH = "${ktstr(spec.name)}"
private const val OPTION_APIKEY = "apikey"
private const val NOT_FOUND = "__NOTFOUND__"

fun prepareAuth(ctx: Context): Spec {
  val spec = ctx.spec
    ?: throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")

  val query = spec.query
  val options = ctx.client!!.optionsMap()

  // Public APIs that need no auth omit the options.auth block entirely.
  if (options["auth"] == null) {
    query.remove(QUERY_AUTH)
    return spec
  }

  val apikey = Struct.getprop(options, OPTION_APIKEY, NOT_FOUND)

` + SKIP + `
  if (skip) {
    query.remove(QUERY_AUTH)
  } else {
    val apikeyVal = if (apikey is String) apikey else ""
    // NO PREFIX IN A QUERY STRING. \`?${spec.name}=Bearer%20abc\` is not a
    // thing any API reads; the prefix is a header convention, so
    // options.auth.prefix is dropped here deliberately rather than silently
    // concatenated.
    query[QUERY_AUTH] = apikeyVal
  }

  return spec
}
`
}


function renderCookie(spec: AuthSpec): string {
  return head(spec) + `import ${spec.kotlinpackage}.core.Context
import ${spec.kotlinpackage}.core.Spec
import ${spec.kotlinpackage}.utility.struct.Struct

private const val COOKIE_HEADER = "cookie"
private const val COOKIE_AUTH = "${ktstr(spec.name)}"
private const val OPTION_APIKEY = "apikey"
private const val NOT_FOUND = "__NOTFOUND__"

// The cookie header minus our own pair, every other cookie untouched.
private fun cookiesWithoutCred(headers: MutableMap<String, Any?>): String {
  val existing = headers[COOKIE_HEADER]
  if (existing !is String || "" == existing) {
    return ""
  }

  val kept = mutableListOf<String>()
  for (part in existing.split(";")) {
    val piece = part.trim()
    if ("" == piece || COOKIE_AUTH == piece || piece.startsWith("\$COOKIE_AUTH=")) {
      continue
    }
    kept.add(piece)
  }

  return kept.joinToString("; ")
}

// Set (a value) or remove (null) our pair, leaving every other cookie in
// place.
private fun applyCookie(headers: MutableMap<String, Any?>, value: String?) {
  val rest = cookiesWithoutCred(headers)

  if (value == null) {
    if ("" == rest) {
      headers.remove(COOKIE_HEADER)
    } else {
      headers[COOKIE_HEADER] = rest
    }
    return
  }

  val pair = "\$COOKIE_AUTH=\$value"
  headers[COOKIE_HEADER] = if ("" == rest) pair else "\$rest; \$pair"
}

fun prepareAuth(ctx: Context): Spec {
  val spec = ctx.spec
    ?: throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")

  val headers = spec.headers
  val options = ctx.client!!.optionsMap()

  // Public APIs that need no auth omit the options.auth block entirely.
  if (options["auth"] == null) {
    applyCookie(headers, null)
    return spec
  }

  val apikey = Struct.getprop(options, OPTION_APIKEY, NOT_FOUND)

` + SKIP + `
  if (skip) {
    applyCookie(headers, null)
  } else {
    val apikeyVal = if (apikey is String) apikey else ""
    // NO PREFIX IN A COOKIE either - a cookie carries a bare \`name=value\`
    // pair, not a header's scheme-prefixed credential.
    applyCookie(headers, apikeyVal)
  }

  return spec
}
`
}


// A Kotlin double-quoted string literal body. These names come from the
// API's own securityScheme, so they are not guaranteed to be bare
// identifiers — and `$` has to go too, because Kotlin reads it as a string
// template introducer rather than as a dollar sign.
function ktstr(s: string): string {
  return String(s)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\$/g, '\\$')
}


export {
  PrepareAuth
}
