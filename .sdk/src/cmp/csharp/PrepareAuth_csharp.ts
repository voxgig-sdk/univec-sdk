
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
        // True HTTP Basic Auth needs TWO credentials, base64-joined - a
        // single token in the header (the branch below) can never
        // authenticate against an API that actually checks
        // \`Authorization: Basic base64(user:pass)\`.
        if (StructUtils.GetPath(options, StructUtils.Jt("auth", "basic")) is bool isBasic &&
            isBasic)
        {
            var secret = StructUtils.GetProp(options, OptionSecret, NotFound);

            var noApikey = apikey == null ||
                (apikey is string akStr && (akStr == NotFound || akStr == ""));
            var noSecret = secret == null ||
                (secret is string skStr && (skStr == NotFound || skStr == ""));

            if (noApikey || noSecret)
            {
                headers.Remove(HeaderAuth);
            }
            else
            {
                var basicPrefix = "";
                if (StructUtils.GetPath(options, StructUtils.Jt("auth", "prefix")) is string bp)
                {
                    basicPrefix = bp;
                }
                var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(
                    (apikey as string ?? "") + ":" + (secret as string ?? "")));
                headers[HeaderAuth] = basicPrefix == ""
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

        var apikey = StructUtils.GetProp(options, OptionApikey, NotFound);
${basicBlock}
        var skip = apikey == null ||
            (apikey is string apikeyStr && (apikeyStr == NotFound || apikeyStr == ""));

        if (skip)
        {
            headers.Remove(HeaderAuth);
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
            headers[HeaderAuth] = authPrefix == ""
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

        var apikey = StructUtils.GetProp(options, OptionApikey, NotFound);

        var skip = apikey == null ||
            (apikey is string apikeyStr && (apikeyStr == NotFound || apikeyStr == ""));

        if (skip)
        {
            query.Remove(QueryAuth);
        }
        else
        {
            var apikeyVal = apikey as string ?? "";
            // NO PREFIX IN A QUERY STRING. \`?token=Bearer%20abc\` is not a thing
            // any API reads; the prefix is a header convention, so
            // options.auth.prefix is dropped here deliberately rather than
            // silently concatenated.
            query[QueryAuth] = apikeyVal;
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

    internal static Spec PrepareAuthUtil(Context ctx)
    {
        var spec = ctx.Spec ?? throw ctx.MakeError("auth_no_spec",
            "Expected context spec property to be defined.");

        var headers = spec.Headers;
        var options = ctx.Client!.OptionsMap();

        // Public APIs that need no auth omit the options.auth block entirely.
        if (!options.TryGetValue("auth", out var auth) || auth == null)
        {
            // Nothing of ours to remove: the credential rides INSIDE the
            // shared cookie header, which this function only ever appends to.
            // Returning here is what withholds it.
            return spec;
        }

        var apikey = StructUtils.GetProp(options, OptionApikey, NotFound);

        var skip = apikey == null ||
            (apikey is string apikeyStr && (apikeyStr == NotFound || apikeyStr == ""));

        if (!skip)
        {
            var apikeyVal = apikey as string ?? "";
            // Append, never assign: a cookie header set by options.headers
            // would otherwise be clobbered by the credential. No prefix - a
            // cookie value is the credential itself.
            var existing = StructUtils.GetProp(headers, HeaderCookie, "") as string ?? "";
            var pair = CookieAuth + "=" + apikeyVal;
            headers[HeaderCookie] = existing == ""
                ? pair
                : existing + "; " + pair;
        }

        return spec;
    }
}
`
}


function csstr(s: string): string {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}


export {
  PrepareAuth
}
