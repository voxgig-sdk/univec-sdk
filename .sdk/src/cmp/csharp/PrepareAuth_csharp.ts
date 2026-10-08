
import {
  Content,
  File,
  Folder,
  cmp,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
} from '@voxgig/sdkgen'


import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const PrepareAuth = cmp(async function PrepareAuth(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const active = !authSwitchedOff(model)
  const where = resolveAuthIn(model)
  const name = resolveAuthName(model)
  const basic = isHttpBasicAuth(model)

  Folder({ name: 'utility' }, () => {
    File({ name: 'PrepareAuth.' + target.ext }, () => {
      Content(render({
        Name: model.const.Name,
        active,
        where,
        name,
        basic,
      }))
    })
  })
})


function authSwitchedOff(model: any): boolean {
  const auth = getModelPath(model, `main.${KIT}.config.auth`,
    { only_active: false, required: false })
  return null != auth && false === auth.active
}


function render(spec: {
  Name: string, active: boolean, where: string, name: string, basic: boolean
}): string {
  const Name = spec.Name

  if (!spec.active) {
    return `// ${Name} SDK utility: prepareAuth - this SDK is built with auth
// switched off, so there is no credential to place.

namespace ${Name}Sdk.Util;

public static partial class SdkUtility
{
    // Still in the pipeline: MakeSpec calls PrepareAuth unconditionally, and
    // a missing spec is still the same error it always was.
    internal static Spec PrepareAuthUtil(Context ctx)
    {
        return ctx.Spec ?? throw ctx.MakeError("auth_no_spec",
            "Expected context spec property to be defined.");
    }
}
`
  }

  if ('query' === spec.where) {
    return renderQuery(Name, csstr(spec.name))
  }

  if ('cookie' === spec.where) {
    return renderCookie(Name, csstr(spec.name))
  }

  return renderHeader(Name, csstr(String(spec.name).toLowerCase()), spec.basic)
}


function renderHeader(Name: string, cred: string, basic: boolean): string {
  // HTTP Basic is header-only by definition: the scheme is
  // `Authorization: Basic base64(user:pass)`. It cannot be expressed as a
  // query parameter or a cookie, so the branch is emitted only here, and
  // only when the model says this API actually uses it - a bearer SDK
  // carries none of it.
  const basicConst = basic ? `
    private const string OptionSecret = "secret";` : ''

  const basicBlock = basic ? `
        // True HTTP Basic Auth joins the two credentials, base64-encoded - a
        // single token in the header (the branch below) can never
        // authenticate against an API that actually checks
        // \`Authorization: Basic base64(user:pass)\`. The password may be
        // empty (RFC 7617): Lob, for one, documents the key as the user with
        // a blank password (\`curl -u key:\`).
        if (StructUtils.GetPath(options, StructUtils.Jt("auth", "basic")) is bool isBasic &&
            isBasic)
        {
            var secret = StructUtils.GetProp(options, OptionSecret, NotFound);

            var noApikey = apikey == null ||
                (apikey is string akStr && (akStr == NotFound || akStr == ""));
            var noSecret = secret == null ||
                (secret is string skStr && (skStr == NotFound || skStr == ""));

            if (noApikey)
            {
                headers.Remove(name);
            }
            else
            {
                var basicPrefix = "";
                if (StructUtils.GetPath(options, StructUtils.Jt("auth", "prefix")) is string bp)
                {
                    basicPrefix = bp;
                }
                var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(
                    (apikey as string ?? "") + ":" + (noSecret ? "" : secret as string ?? "")));
                // The joined, encoded pair is a wire form neither credential's
                // own registration covers.
                ctx.Utility!.CleanAdd(ctx, b64);
                headers[name] = basicPrefix == ""
                    ? b64
                    : basicPrefix + " " + b64;
            }

            return spec;
        }
` : ''

  return `// ${Name} SDK utility: prepareAuth - shape the ${cred} header
// from the client options.

using Voxgig.Struct;

namespace ${Name}Sdk.Util;

public static partial class SdkUtility
{
    private const string HeaderAuth = "${cred}";
    private const string OptionApikey = "apikey";${basicConst}
    private const string NotFound = "__NOTFOUND__";
${authName('HeaderAuth', true)}
    internal static Spec PrepareAuthUtil(Context ctx)
    {
        var spec = ctx.Spec ?? throw ctx.MakeError("auth_no_spec",
            "Expected context spec property to be defined.");

        var headers = spec.Headers;
        var options = ctx.Client!.OptionsMap();

        // Public APIs that need no auth omit the options.auth block entirely.
        if (!options.TryGetValue("auth", out var auth) || auth == null)
        {
            headers.Remove(HeaderAuth);
            return spec;
        }

        var name = PrepareAuthName(options);

        // A credential left under the declared name would travel beside the renamed one.
        if (name != HeaderAuth)
        {
            headers.Remove(HeaderAuth);
        }

        var apikey = StructUtils.GetProp(options, OptionApikey, NotFound);
${basicBlock}
        var skip = apikey == null ||
            (apikey is string apikeyStr && (apikeyStr == NotFound || apikeyStr == ""));

        if (skip)
        {
            headers.Remove(name);
        }
        else
        {
            var authPrefix = "";
            if (StructUtils.GetPath(options, StructUtils.Jt("auth", "prefix")) is string ap)
            {
                authPrefix = ap;
            }
            var apikeyVal = apikey as string ?? "";
            // Empty prefix (raw apiKey credential) must not add a leading space.
            headers[name] = authPrefix == ""
                ? apikeyVal
                : authPrefix + " " + apikeyVal;
        }

        return spec;
    }
}
`
}


// QUERY. MakeSpec fills spec.Query before it calls PrepareAuth, and MakeUrl
// reads spec.Query afterwards (via MakeFetchDef), url-escaping every key and
// value - so the credential placed here reaches the wire as `?name=value`.
function renderQuery(Name: string, cred: string): string {
  return `// ${Name} SDK utility: prepareAuth - carry the API credential in the
// ${cred} query parameter, from the client options.

using Voxgig.Struct;

namespace ${Name}Sdk.Util;

public static partial class SdkUtility
{
    private const string QueryAuth = "${cred}";
    private const string OptionApikey = "apikey";
    private const string NotFound = "__NOTFOUND__";
${authName('QueryAuth', false)}
    internal static Spec PrepareAuthUtil(Context ctx)
    {
        var spec = ctx.Spec ?? throw ctx.MakeError("auth_no_spec",
            "Expected context spec property to be defined.");

        var query = spec.Query;
        var options = ctx.Client!.OptionsMap();

        // Public APIs that need no auth omit the options.auth block entirely.
        if (!options.TryGetValue("auth", out var auth) || auth == null)
        {
            query.Remove(QueryAuth);
            return spec;
        }

        var name = PrepareAuthName(options);

        // A credential left under the declared name would travel beside the renamed one.
        if (name != QueryAuth)
        {
            query.Remove(QueryAuth);
        }

        var apikey = StructUtils.GetProp(options, OptionApikey, NotFound);

        var skip = apikey == null ||
            (apikey is string apikeyStr && (apikeyStr == NotFound || apikeyStr == ""));

        if (skip)
        {
            query.Remove(name);
        }
        else
        {
            var apikeyVal = apikey as string ?? "";
            // NO PREFIX IN A QUERY STRING. \`?token=Bearer%20abc\` is not a thing
            // any API reads; the prefix is a header convention, so
            // options.auth.prefix is dropped here deliberately rather than
            // silently concatenated.
            query[name] = apikeyVal;
        }

        return spec;
    }
}
`
}


function renderCookie(Name: string, cred: string): string {
  return `// ${Name} SDK utility: prepareAuth - carry the API credential in the
// ${cred} cookie, from the client options.

using Voxgig.Struct;

namespace ${Name}Sdk.Util;

public static partial class SdkUtility
{
    private const string CookieAuth = "${cred}";
    private const string HeaderCookie = "cookie";
    private const string OptionApikey = "apikey";
    private const string NotFound = "__NOTFOUND__";
${authName('CookieAuth', false)}
    // Rewrites the cookie header with the named pair removed, then set to the
    // value when it is not null; every other cookie is kept in order.
    private static void PrepareAuthCookie(Dictionary<string, object?> headers, string name, string? value)
    {
        var existing = headers.TryGetValue(HeaderCookie, out var current) ? current as string : null;
        var kept = CookieKeep(existing ?? "", new List<string> { name });
        if (value != null)
        {
            kept.Add(name + "=" + value);
        }
        if (kept.Count == 0)
        {
            headers.Remove(HeaderCookie);
        }
        else
        {
            headers[HeaderCookie] = string.Join("; ", kept);
        }
    }

    internal static Spec PrepareAuthUtil(Context ctx)
    {
        var spec = ctx.Spec ?? throw ctx.MakeError("auth_no_spec",
            "Expected context spec property to be defined.");

        var headers = spec.Headers;
        var options = ctx.Client!.OptionsMap();

        // Public APIs that need no auth omit the options.auth block entirely.
        if (!options.TryGetValue("auth", out var auth) || auth == null)
        {
            PrepareAuthCookie(headers, CookieAuth, null);
            return spec;
        }

        var name = PrepareAuthName(options);

        // A credential left under the declared name would travel beside the renamed one.
        if (name != CookieAuth)
        {
            PrepareAuthCookie(headers, CookieAuth, null);
        }

        var apikey = StructUtils.GetProp(options, OptionApikey, NotFound);

        var skip = apikey == null ||
            (apikey is string apikeyStr && (apikeyStr == NotFound || apikeyStr == ""));

        // Spliced in, replacing an earlier pair of the same name, beside any
        // cookie the caller set. No prefix - a cookie value is the credential
        // itself.
        PrepareAuthCookie(headers, name, skip ? null : apikey as string ?? "");

        return spec;
    }
}
`
}


// The client's `auth.name` option, when set, replaces the declared name; a
// header name travels lower-cased.
function authName(declared: string, header: boolean): string {
  return `
    // The client's auth.name option, when set, replaces the name the API declares.
    private static string PrepareAuthName(object? options) =>
        StructUtils.GetPath(options, StructUtils.Jt("auth", "name")) is string name && name != ""
            ? ${header ? 'name.ToLowerInvariant()' : 'name'} : ${declared};
`
}


function csstr(s: string): string {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}


export {
  PrepareAuth
}
