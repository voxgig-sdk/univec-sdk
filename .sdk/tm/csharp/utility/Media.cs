// Univec SDK utility: media.

using Voxgig.Struct;

namespace UnivecSdk.Util;

// The media types a point declares: `response` (the model's `rs`) for the
// Accept header, and `body` (the model's `rb`) for the request body.
public static partial class SdkUtility
{
    // The data key holding a raw request body. Like `$action`, it can never
    // be a declared argument name.
    internal const string RawBody = "$body";

    internal static bool IsJsonMedia(object? media)
    {
        var m = (media as string ?? "").Split(';', 2)[0].Trim().ToLowerInvariant();
        return m == "application/json" || m == "text/json" || m.EndsWith("+json");
    }

    // The declared JSON type alone, else every declared type in the model's
    // order; null when no success response declares a body.
    internal static string? AcceptOf(object? point)
    {
        var res = StructUtils.GetProp(point, "response");
        if (StructUtils.GetProp(res, "media") is not string media || media == "")
        {
            return null;
        }
        if ("json".Equals(StructUtils.GetProp(res, "kind")))
        {
            return media;
        }
        var types = new List<string> { media };
        if (StructUtils.GetProp(res, "alternatives") is List<object?> alts)
        {
            foreach (var alt in alts)
            {
                if (StructUtils.GetProp(alt, "media") is string m && m != "")
                {
                    types.Add(m);
                }
            }
        }
        return string.Join(", ", types);
    }

    internal static bool IsRawRequest(object? point)
    {
        return "raw".Equals(StructUtils.GetProp(StructUtils.GetProp(point, "body"), "kind"));
    }

    internal static bool IsJsonRequest(object? point)
    {
        return "json".Equals(StructUtils.GetProp(StructUtils.GetProp(point, "body"), "kind"));
    }

    // Bytes or a stream go as given. A map or a list is JSON, and so is a
    // scalar on a point that declares a JSON body.
    internal static object RequestBody(object? point, object body)
    {
        if (body is byte[] || body is Stream)
        {
            return body;
        }
        if (StructUtils.IsNode(body) || IsJsonRequest(point))
        {
            return StructUtils.Jsonify(body);
        }
        return body;
    }

    private static bool HasHeader(Dictionary<string, object?> headers, string name)
    {
        return headers.Keys.Any(k => k.ToLowerInvariant() == name);
    }

    // A caller's accept wins. A declared request type replaces each JSON
    // content-type, the SDK default, and leaves any other the caller set.
    internal static Dictionary<string, object?> MediaHeaders(object? point,
        Dictionary<string, object?> headers)
    {
        var accept = AcceptOf(point);
        if (accept != null && !HasHeader(headers, "accept"))
        {
            headers["accept"] = accept;
        }

        var body = StructUtils.GetProp(point, "body");
        var kind = StructUtils.GetProp(body, "kind");
        if (("raw".Equals(kind) || "json".Equals(kind)) &&
            StructUtils.GetProp(body, "media") is string media && media != "")
        {
            foreach (var k in new List<string>(headers.Keys))
            {
                if (k.ToLowerInvariant() == "content-type" && IsJsonMedia(headers[k]))
                {
                    headers.Remove(k);
                }
            }
            if (!HasHeader(headers, "content-type"))
            {
                headers["content-type"] = media;
            }
        }

        return headers;
    }

    // Bytes, a Stream or a string, sent as they are. A Stream can be read
    // once, so it is read here, before the first attempt, and a retry sends
    // the same bytes again.
    internal static object? RawBodyOf(Dictionary<string, object?>? reqdata)
    {
        var body = reqdata != null && reqdata.TryGetValue(RawBody, out var found) ? found : null;
        if (body is Stream stream)
        {
            using var buffer = new MemoryStream();
            stream.CopyTo(buffer);
            return buffer.ToArray();
        }
        return body;
    }
}
