// Univec SDK utility: graphql
//
// GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
// produces uses this file unchanged. The API-specific part — which
// operations exist and what each one's document is — is model data,
// computed once by apidef and emitted into Config.
//
// Two jobs:
//
//   GraphqlBodyUtil   — build { query, variables } for a point, binding the
//                       op's arguments to the document's declared variables.
//
//   GraphqlErrorsUtil — lift a GraphQL failure into an SDK error. GraphQL
//                       reports failures as a top-level `errors` array under
//                       HTTP 200, so the status-driven path in ResultBasic
//                       never sees them.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    // Content type every GraphQL-over-HTTP request uses.
    internal const string GraphqlContentType = "application/json";

    // Map a GraphQL error to the same error codes the HTTP path produces,
    // so a caller handles auth or rate limiting identically on both
    // transports. Servers put the machine-readable code in
    // `extensions.code`; Linear-style APIs use `extensions.type`.
    internal static string GraphqlErrorCode(object? gqlerr)
    {
        var ext = StructUtils.GetProp(gqlerr, "extensions");

        var code = StructUtils.GetProp(ext, "code") as string;
        if (string.IsNullOrEmpty(code))
        {
            code = StructUtils.GetProp(ext, "type") as string;
        }

        var raw = (code ?? "").ToUpperInvariant();

        if (raw.Contains("AUTH") || raw.Contains("FORBIDDEN")
            || raw.Contains("UNAUTHENTICATED"))
        {
            return "request_auth";
        }
        if (raw.Contains("RATELIMIT") || raw.Contains("RATE_LIMIT")
            || raw.Contains("TOO_MANY"))
        {
            return "request_ratelimit";
        }
        if (raw.Contains("BAD_USER_INPUT") || raw.Contains("VALIDATION")
            || raw.Contains("INVALID"))
        {
            return "request_invalid";
        }

        return "request_graphql";
    }

    // Build the request body for a GraphQL point.
    //
    // Variables come from the op's own arguments: a named variable binds to
    // the like-named argument (`from`), and the input-object variable
    // (empty `from`) takes the request data as a whole — which is what
    // makes a generated create/update call look exactly like its REST
    // equivalent.
    internal static object? GraphqlBodyUtil(Context ctx)
    {
        var gql = StructUtils.GetProp(ctx.Point, "graphql")
            as Dictionary<string, object?>;
        if (null == gql)
        {
            return null;
        }

        // reqmatch/reqdata hold the caller's arguments for THIS call;
        // data/match hold the entity's current state. Which pair depends on
        // whether the op takes match or data input. A named variable falls
        // back to the current state, so updating a loaded entity with just
        // {title} still binds the stored id the mutation requires.
        var reqsrc = ctx.Reqmatch;
        var datasrc = ctx.Match;
        if (null != ctx.Op && "data" == ctx.Op.Input)
        {
            reqsrc = ctx.Reqdata;
            datasrc = ctx.Data;
        }
        reqsrc ??= new Dictionary<string, object?>();
        datasrc ??= new Dictionary<string, object?>();

        var variables = new Dictionary<string, object?>();

        var varlist = StructUtils.GetProp(gql, "vars") as List<object?>;
        if (null != varlist)
        {
            foreach (var entry in varlist)
            {
                if (entry is not Dictionary<string, object?> spec)
                {
                    continue;
                }

                var name = StructUtils.GetProp(spec, "name") as string;
                if (null == name)
                {
                    continue;
                }

                var from = StructUtils.GetProp(spec, "from") as string;

                if (string.IsNullOrEmpty(from))
                {
                    // The input object IS the request body. Strip the
                    // action selector, which is an SDK-side point
                    // discriminator, not an API field.
                    var body = new Dictionary<string, object?>();
                    foreach (var kv in reqsrc)
                    {
                        if ("$action" != kv.Key)
                        {
                            body[kv.Key] = kv.Value;
                        }
                    }
                    variables[name] = body;
                    continue;
                }

                // Only send variables the caller actually supplied: sending
                // an explicit null would clear a field on many APIs.
                var val = StructUtils.GetProp(reqsrc, from)
                    ?? StructUtils.GetProp(datasrc, from);
                if (null != val)
                {
                    variables[name] = val;
                }
            }
        }

        return new Dictionary<string, object?>
        {
            ["query"] = StructUtils.GetProp(gql, "doc"),
            ["variables"] = variables,
        };
    }

    // Inspect a decoded GraphQL response body and record a failure when the
    // server reported one. Returns true when an error was recorded.
    //
    // Partial data (`data` alongside `errors`) is treated as failure: the
    // REST surface has no partial-success concept, and silently returning
    // half an object would be worse than failing.
    internal static bool GraphqlErrorsUtil(Context ctx)
    {
        var result = ctx.Result;

        if (null == result || null == ctx.Point)
        {
            return false;
        }

        if ("graphql" != StructUtils.GetProp(ctx.Point, "kind") as string)
        {
            return false;
        }

        if (StructUtils.GetProp(result.Body, "errors") is not List<object?> errors
            || 0 == errors.Count)
        {
            return false;
        }

        var first = errors[0];
        var msg = StructUtils.GetProp(first, "message") as string;
        if (string.IsNullOrEmpty(msg))
        {
            msg = "graphql error";
        }
        if (1 < errors.Count)
        {
            msg = msg + " (+" + (errors.Count - 1) + " more)";
        }

        result.Err = ctx.MakeError(GraphqlErrorCode(first), "graphql: " + msg);
        result.Ok = false;

        return true;
    }
}
