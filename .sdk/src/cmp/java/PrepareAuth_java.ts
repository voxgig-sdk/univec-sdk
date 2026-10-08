
import {
  Content,
  File,
  Folder,
  cmp,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
} from '@voxgig/sdkgen'


import { javaPackage } from './utility_java'


const PrepareAuth = cmp(async function PrepareAuth(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const javapackage = javaPackage(model)

  const active = !isAuthSuppressed(model)
  const where = resolveAuthIn(model)
  const name = resolveAuthName(model)
  const basic = isHttpBasicAuth(model)

  Folder({ name: 'utility' }, () => {
    File({ name: 'PrepareAuth.' + target.ext }, () => {
      Content(render({ javapackage, active, where, name, basic }))
    })
  })
})


function render(spec: {
  javapackage: string, active: boolean, where: string, name: string,
  basic: boolean
}): string {
  const jp = spec.javapackage

  if (!spec.active) {
    return `package ${jp}.utility;

import ${jp}.core.Context;
import ${jp}.core.Spec;

// This API declares no authentication, so there is no credential to place.
// The class stays in the pipeline because Register wires prepareAuth
// unconditionally and MakeSpec calls it on every request.
final class PrepareAuth {

  private PrepareAuth() {}

  static Spec prepareAuth(Context ctx) {
    Spec spec = ctx.spec;
    if (spec == null) {
      throw ctx.makeError("auth_no_spec",
          "Expected context spec property to be defined.");
    }

    return spec;
  }
}
`
  }

  const header = 'header' === spec.where
  const query = 'query' === spec.where
  const cookie = 'cookie' === spec.where

  // HTTP Basic is header-only by definition: the scheme is
  // `Authorization: Basic base64(user:pass)`. It cannot be expressed as a
  // query parameter or a cookie, so the branch is emitted only where it
  // can mean something.
  const basicBranch = spec.basic && header

  // The bag the credential lands in, per placement. Cookies ride the
  // header bag because a cookie IS a header.
  const bag = query ? 'query' : 'headers'

  const imports = [
    ...(basicBranch ? [
      'import java.nio.charset.StandardCharsets;',
      'import java.util.Base64;',
    ] : []),
    'import java.util.List;',
    'import java.util.Map;',
  ].join('\n')

  const consts = [
    `  static final String CRED_NAME = "${javastr(credName(spec.where, spec.name))}";`,
    ...(cookie ? ['  static final String COOKIE_HEADER = "cookie";'] : []),
    '  static final String OPTION_APIKEY = "apikey";',
    ...(basicBranch ? ['  static final String OPTION_SECRET = "secret";'] : []),
    '  static final String NOT_FOUND = "__NOTFOUND__";',
  ].join('\n')

  const basicBlock = basicBranch ? `
    // True HTTP Basic Auth joins the two credentials, base64-encoded - a single
    // token in the header (the branch below) can never authenticate against
    // an API that actually checks \`Authorization: Basic base64(user:pass)\`.
    // The password may be empty (RFC 7617): Lob, for one, documents the key as
    // the user with a blank password (\`curl -u key:\`).
    if (Boolean.TRUE.equals(Struct.getpath(options, List.of("auth", "basic")))) {
      Object secret = Struct.getprop(options, OPTION_SECRET, NOT_FOUND);
      boolean noApikey = !(apikey instanceof String)
          || NOT_FOUND.equals(apikey) || "".equals(apikey);
      boolean noSecret = !(secret instanceof String)
          || NOT_FOUND.equals(secret) || "".equals(secret);

      if (noApikey) {
        headers.remove(name);
      }
      else {
        String basicPrefix = "";
        Object bp = Struct.getpath(options, List.of("auth", "prefix"));
        if (bp instanceof String) {
          basicPrefix = (String) bp;
        }
        String b64 = Base64.getEncoder().encodeToString(
            ((String) apikey + ":" + (noSecret ? "" : (String) secret)).getBytes(StandardCharsets.UTF_8));
        // The joined, encoded pair is a wire form neither credential's own
        // registration covers.
        ctx.utility.cleanAdd.apply(ctx, b64);
        if ("".equals(basicPrefix)) {
          headers.put(name, b64);
        }
        else {
          headers.put(name, basicPrefix + " " + b64);
        }
      }

      return spec;
    }
` : ''

  return `package ${jp}.utility;

${imports}

import ${jp}.core.Context;
import ${jp}.core.Spec;
import ${jp}.utility.struct.Struct;

final class PrepareAuth {

  private PrepareAuth() {}

${consts}

  // The client's auth.name option, when set, replaces the name the API declares.
  static String authName(Map<String, Object> options) {
    Object name = Struct.getpath(options, List.of("auth", "name"));
    return name instanceof String && !"".equals(name)
        ? ${header ? '((String) name).toLowerCase(java.util.Locale.ROOT)' : '(String) name'} : CRED_NAME;
  }
${cookie ? COOKIE_HELPER : ''}
  static Spec prepareAuth(Context ctx) {
    Spec spec = ctx.spec;
    if (spec == null) {
      throw ctx.makeError("auth_no_spec",
          "Expected context spec property to be defined.");
    }

    Map<String, Object> ${bag} = spec.${bag};
    Map<String, Object> options = ctx.client.optionsMap();

    // Public APIs that need no auth omit the options.auth block entirely.
    if (options.get("auth") == null) {
      ${clear(spec.where, 'CRED_NAME')}
      return spec;
    }

    String name = authName(options);

    // A credential left under the declared name would travel beside the renamed one.
    if (!name.equals(CRED_NAME)) {
      ${clear(spec.where, 'CRED_NAME')}
    }

    Object apikey = Struct.getprop(options, OPTION_APIKEY, NOT_FOUND);
${basicBlock}
    boolean skip = false;
    if (apikey == null) {
      skip = true;
    }
    else if (apikey instanceof String
        && (NOT_FOUND.equals(apikey) || "".equals(apikey))) {
      skip = true;
    }

    if (skip) {
      ${clear(spec.where, 'name')}
    }
    else {
${place(spec.where, 'name')}
    }

    return spec;
  }
}
`
}


function credName(where: string, name: string): string {
  return 'header' === where ? name.toLowerCase() : name
}


// A cookie has no header of its own: place() writes it into `cookie` as
// `name=value`, so clear() frees that pair, not a header of that name.
function clear(where: string, name: string): string {
  if ('cookie' === where) {
    return `applyCookie(headers, ${name}, null);`
  }
  return 'query' === where ? `query.remove(${name});` : `headers.remove(${name});`
}


// The cookie header is shared with whatever cookies the caller set, so the
// credential's pair is spliced in and out rather than appended.
const COOKIE_HELPER = `
  // Rewrites the cookie header with the named pair removed, then set to the
  // value when it is not null; every other cookie is kept in order.
  static void applyCookie(Map<String, Object> headers, String name, String value) {
    Object existing = headers.get(COOKIE_HEADER);
    String cookie = existing instanceof String ? (String) existing : "";
    List<String> kept = PrepareHeaders.cookieKeep(cookie, List.of(name));
    if (value != null) {
      kept.add(name + "=" + value);
    }
    if (kept.isEmpty()) {
      headers.remove(COOKIE_HEADER);
    }
    else {
      headers.put(COOKIE_HEADER, String.join("; ", kept));
    }
  }
`


function place(where: string, name: string): string {
  if ('query' === where) {
    return `      String apikeyVal = apikey instanceof String ? (String) apikey : "";
      // NO PREFIX IN A QUERY STRING: ?name=Bearer%20abc is not a thing any
      // API reads, so the auth.prefix option is dropped here deliberately.
      query.put(${name}, apikeyVal);`
  }

  if ('cookie' === where) {
    return `      String apikeyVal = apikey instanceof String ? (String) apikey : "";
      // Spliced in, replacing an earlier pair of the same name, beside any
      // cookie the caller set. No prefix, for the same reason a query
      // parameter carries none.
      applyCookie(headers, ${name}, apikeyVal);`
  }

  return `      String authPrefix = "";
      Object ap = Struct.getpath(options, List.of("auth", "prefix"));
      if (ap instanceof String) {
        authPrefix = (String) ap;
      }
      String apikeyVal = apikey instanceof String ? (String) apikey : "";
      // Empty prefix (raw apiKey credential) must not add a leading space.
      if ("".equals(authPrefix)) {
        headers.put(${name}, apikeyVal);
      }
      else {
        headers.put(${name}, authPrefix + " " + apikeyVal);
      }`
}


function javastr(s: string): string {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}


export {
  PrepareAuth
}
