// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/Sigv4.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Signature Version 4, hand-rolled.
//
// The AWS providers need exactly one thing from the AWS SDK - request
// signing - and taking the SDK for it would break the no-dependency rule
// that keeps ten ports honest. SigV4 is a stable, published algorithm
// built from HMAC-SHA256, which the base class library already has.
//
// `Sign` is pure: the caller passes the timestamp, so the same input
// yields the same signature everywhere. That is what lets the shared spec
// carry known-answer cases that all ten ports must reproduce bit-for-bit,
// and lets the integration mock recompute the signature server-side.
//
// SIGV4 IS PLUGIN CODE, and moved here with the AWS providers it serves:
// THE CORE OF NO PORT IMPORTS A HASH FUNCTION. This file lives in the
// VoxgigSekretoPlugins assembly, so an application whose chain names only
// built-in kinds links no System.Security.Cryptography through sekreto.
// See docs/design/plugin-providers.md.
//
// A port of typescript/plugins/sigv4.ts, which is canonical.

using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Voxgig.Sekreto.Plugins
{
    public static class Sigv4
    {
        private static readonly Regex Whitespace = new Regex("\\s+", RegexOptions.Compiled);

        /// <summary>
        /// Sign one request. Input keys: method, url, headers?, body?,
        /// service, region, keyid, secret, session?, and datetime
        /// (`YYYYMMDDTHHMMSSZ`; passed in, never sampled, so the function
        /// stays pure). Returns the headers to attach to the request:
        /// authorization, x-amz-date, and x-amz-security-token when a
        /// session token was given.
        /// </summary>
        public static Dictionary<string, object> Sign(Dictionary<string, object> input)
        {
            var url = new Uri(Text(input.GetValueOrDefault("url")));

            string datetime = Text(input.GetValueOrDefault("datetime"));
            string date = datetime.Substring(0, 8);
            string body = Text(input.GetValueOrDefault("body")) ?? "";

            string method = Text(input.GetValueOrDefault("method"));
            string service = Text(input.GetValueOrDefault("service"));
            string region = Text(input.GetValueOrDefault("region"));
            string keyid = Text(input.GetValueOrDefault("keyid"));
            string secret = Text(input.GetValueOrDefault("secret"));
            string session = Text(input.GetValueOrDefault("session"));

            // Every header that will be signed: the caller's extras, plus
            // host and x-amz-date (and the session token when present),
            // lower-cased and trimmed the way the canonical form requires.
            // Canonical header values are trimmed AND internally collapsed -
            // AWS folds sequential whitespace to one space before signing, so
            // a header like "a  b" must sign as "a b" or the service refuses
            // it.
            var headers = new Dictionary<string, string>();

            if (input.GetValueOrDefault("headers") is Dictionary<string, object> extra)
            {
                foreach (var entry in extra)
                {
                    headers[entry.Key.ToLowerInvariant()] =
                        Whitespace.Replace(Convert.ToString(entry.Value).Trim(), " ");
                }
            }

            // Uri.Authority is the host plus any non-default port, exactly
            // the WHATWG `host` the canonical implementation signs.
            headers["host"] = url.Authority;
            headers["x-amz-date"] = datetime;
            if (!string.IsNullOrEmpty(session))
            {
                headers["x-amz-security-token"] = session;
            }

            var names = new List<string>(headers.Keys);
            names.Sort(StringComparer.Ordinal);

            var canonicalheaders = new StringBuilder();
            foreach (string name in names)
            {
                canonicalheaders.Append(name).Append(':').Append(headers[name]).Append('\n');
            }
            string signedheaders = string.Join(";", names);

            string path = url.AbsolutePath;
            if (0 == path.Length)
            {
                path = "/";
            }

            string canonicalrequest = string.Join("\n", new[]
            {
                method.ToUpperInvariant(),
                path,
                CanonicalQuery(url.Query.TrimStart('?')),
                canonicalheaders.ToString(),
                signedheaders,
                Sha256Hex(body),
            });

            string scope = date + "/" + region + "/" + service + "/aws4_request";

            string stringtosign = string.Join("\n", new[]
            {
                "AWS4-HMAC-SHA256",
                datetime,
                scope,
                Sha256Hex(canonicalrequest),
            });

            byte[] kdate = Hmac(Encoding.UTF8.GetBytes("AWS4" + secret), date);
            byte[] kregion = Hmac(kdate, region);
            byte[] kservice = Hmac(kregion, service);
            byte[] ksigning = Hmac(kservice, "aws4_request");
            string signature = Hex(Hmac(ksigning, stringtosign));

            var out_ = new Dictionary<string, object>
            {
                ["authorization"] = "AWS4-HMAC-SHA256 Credential=" + keyid + "/" + scope
                    + ", SignedHeaders=" + signedheaders + ", Signature=" + signature,
                ["x-amz-date"] = datetime,
            };

            if (!string.IsNullOrEmpty(session))
            {
                out_["x-amz-security-token"] = session;
            }

            return out_;
        }

        /// <summary>
        /// The canonical query string: each pair RFC 3986-escaped, sorted by
        /// escaped key then escaped value.
        /// </summary>
        private static string CanonicalQuery(string query)
        {
            if ("" == query)
            {
                return "";
            }

            var pairs = new List<string[]>();

            foreach (string pair in query.Split('&'))
            {
                int eq = pair.IndexOf('=');
                string key = -1 == eq ? pair : pair.Substring(0, eq);
                string value = -1 == eq ? "" : pair.Substring(eq + 1);
                pairs.Add(new[]
                {
                    UriEscape(Uri.UnescapeDataString(key)),
                    UriEscape(Uri.UnescapeDataString(value)),
                });
            }

            pairs.Sort((left, right) =>
            {
                int bykey = string.CompareOrdinal(left[0], right[0]);
                return 0 == bykey ? string.CompareOrdinal(left[1], right[1]) : bykey;
            });

            var out_ = new List<string>();
            foreach (string[] pair in pairs)
            {
                out_.Add(pair[0] + "=" + pair[1]);
            }

            return string.Join("&", out_);
        }

        /// <summary>
        /// RFC 3986 escaping, spelled out rather than borrowed: AWS wants
        /// every byte outside the unreserved set percent-encoded with
        /// uppercase hex, including `!`, `'`, `(`, `)` and `*`, and library
        /// encoders disagree on exactly those.
        /// </summary>
        private static string UriEscape(string text)
        {
            var out_ = new StringBuilder();

            foreach (byte head in Encoding.UTF8.GetBytes(text))
            {
                char ch = (char)head;

                if (('A' <= ch && 'Z' >= ch) || ('a' <= ch && 'z' >= ch)
                    || ('0' <= ch && '9' >= ch)
                    || '-' == ch || '_' == ch || '.' == ch || '~' == ch)
                {
                    out_.Append(ch);
                }
                else
                {
                    out_.Append('%').Append(((int)head).ToString("X2"));
                }
            }

            return out_.ToString();
        }

        private static string Sha256Hex(string text)
        {
            return Hex(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
        }

        private static byte[] Hmac(byte[] key, string text)
        {
            using var mac = new HMACSHA256(key);
            return mac.ComputeHash(Encoding.UTF8.GetBytes(text));
        }

        private static string Hex(byte[] data)
        {
            var out_ = new StringBuilder(data.Length * 2);

            foreach (byte head in data)
            {
                out_.Append(head.ToString("x2"));
            }

            return out_.ToString();
        }

        private static string Text(object value)
        {
            return null == value ? null : Convert.ToString(value);
        }
    }
}
