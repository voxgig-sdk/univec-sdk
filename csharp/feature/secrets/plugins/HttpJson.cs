// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/HttpJson.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The shared HTTP-JSON client the plugin provider kinds talk through -
// bounded, redirect-refusing - and the two small helpers that go with it.
//
// PLUGIN CODE. This file is in the VoxgigSekretoPlugins assembly, which
// the core does not reference - so a chain of built-ins links no
// System.Net.Http at all. See docs/design/plugin-providers.md.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Text;

using Voxgig.Sekreto;

namespace Voxgig.Sekreto.Plugins
{
    internal static class Url
    {
        /// <summary>
        /// Percent-encode a query value the way canonical's
        /// encodeURIComponent does: UTF-8 bytes as uppercase hex, with
        /// `A-Za-z0-9 - _ . ! ~ * ' ( )` left as they are.
        /// </summary>
        internal static string Encode(string text)
        {
            var out_ = new StringBuilder();

            foreach (byte head in Encoding.UTF8.GetBytes(text ?? ""))
            {
                char ch = (char)head;

                if (('A' <= ch && 'Z' >= ch) || ('a' <= ch && 'z' >= ch)
                    || ('0' <= ch && '9' >= ch)
                    || '-' == ch || '_' == ch || '.' == ch || '!' == ch || '~' == ch
                    || '*' == ch || '\'' == ch || '(' == ch || ')' == ch)
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
    }
    internal static class Http
    {
        /// <summary>
        /// How much of a response body will be read before the store is treated
        /// as having answered incoherently. Ports carry the same bound.
        ///
        /// <para>Far above anything real - the largest legitimate payload this
        /// library fetches is Doppler's whole-config download, measured in
        /// kilobytes. A bound is needed because the TIMEOUT is not one: ten
        /// seconds on a loopback or datacentre link is gigabytes, and the body is
        /// accumulated in memory before it is parsed. This runs on an
        /// application's startup path, so the failure is the application never
        /// starting.</para>
        /// </summary>
        internal const long MaxBody = 8 * 1024 * 1024;

        // AllowAutoRedirect = false: a vault API never legitimately
        // redirects, and a followed redirect carries X-Vault-Token to the
        // target host, which checkaddr - it validates only the configured
        // address - cannot see. A 3xx then surfaces as a store error.
        private static readonly HttpClient Client =
            new HttpClient(new HttpClientHandler
            {
                AllowAutoRedirect = false,

                // A secrets client dials the address it was configured with
                // and nowhere else. UseProxy defaults to true and resolves
                // from the environment WITHOUT exempting loopback, so with
                // HTTP_PROXY set the vault token for a local dev vault went,
                // in the clear, to whatever that variable named. checkaddr
                // permits plaintext to loopback precisely because nothing
                // leaves the machine.
                UseProxy = false,
            })
            { Timeout = TimeSpan.FromSeconds(10) };

        /// <summary>
        /// One JSON round-trip. Network failure is always an error - an
        /// unreachable store is a store that could not answer. So is a
        /// status-200 body that fails to parse as JSON: a success status
        /// promised JSON, and treating the garble as a miss would fall
        /// through to a weaker store. Error statuses may carry any body -
        /// they are decided on status alone.
        /// </summary>
        internal static (int Status, object Body) FetchJson(
            string method, string url, Dictionary<string, string> headers, string body = null)
        {
            var request = new HttpRequestMessage(new HttpMethod(method), url);

            if (null != body)
            {
                request.Content = new ByteArrayContent(Encoding.UTF8.GetBytes(body));
            }

            if (null != headers)
            {
                foreach (var entry in headers)
                {
                    // Content headers (content-type) live on the content, not
                    // the request; try the request first and fall through.
                    if (!request.Headers.TryAddWithoutValidation(entry.Key, entry.Value)
                        && null != request.Content)
                    {
                        request.Content.Headers.TryAddWithoutValidation(entry.Key, entry.Value);
                    }
                }
            }

            int status;
            string text;
            try
            {
                using HttpResponseMessage response = Client.Send(
                    request, HttpCompletionOption.ResponseHeadersRead);
                status = (int)response.StatusCode;

                // Read against MaxBody rather than ReadAsStringAsync, which
                // buffers whatever arrives: an endless body would otherwise be
                // accumulated in memory until the deadline, which on a
                // loopback or datacentre link is gigabytes.
                using Stream stream = response.Content.ReadAsStream();
                var buffer = new byte[64 * 1024];
                using var collected = new MemoryStream();
                int got;
                while (0 < (got = stream.Read(buffer, 0, buffer.Length)))
                {
                    if (MaxBody < collected.Length + got)
                    {
                        // An endless body is a store that could not answer, so
                        // this raises rather than returning a miss.
                        throw new SekretoError(
                            "sekreto: oversized response from " + url.Split('?')[0]);
                    }
                    collected.Write(buffer, 0, got);
                }
                text = Encoding.UTF8.GetString(collected.ToArray());
            }
            catch (SekretoError)
            {
                throw;
            }
            catch (Exception err)
            {
                throw new SekretoError(
                    "sekreto: cannot reach " + url.Split('?')[0] + ": " + err.Message);
            }

            if (!Json.TryParse(text, out object parsed) && 200 == status)
            {
                throw new SekretoError(
                    "sekreto: malformed response from " + url.Split('?')[0]);
            }

            return (status, parsed);
        }
    }
    /// <summary>Helpers shared by the plugin providers.</summary>
    internal static class Renew
    {
        /// <summary>
        /// The instant a logged-in token should be renewed: shortly before
        /// an expiry given in seconds runs out (now + max(seconds - 60, 1)),
        /// or never when the expiry is missing, zero or unreadable. Azure's
        /// endpoints may send expires_in as a string, so numeric text
        /// counts.
        /// </summary>
        internal static DateTimeOffset At(object expires)
        {
            double seconds;

            try
            {
                seconds = null == expires
                    ? 0
                    : Convert.ToDouble(expires, CultureInfo.InvariantCulture);
            }
            catch (FormatException)
            {
                seconds = 0;
            }
            catch (InvalidCastException)
            {
                seconds = 0;
            }
            catch (OverflowException)
            {
                seconds = 0;
            }

            // A century outruns any real lease; anything longer (or NaN)
            // simply never renews, like a missing expiry - and stays
            // representable as a timestamp.
            if (double.IsNaN(seconds) || 0 >= seconds || 3153600000d < seconds)
            {
                return DateTimeOffset.MaxValue;
            }

            return DateTimeOffset.UtcNow.AddSeconds(Math.Max(seconds - 60, 1));
        }
    }
}
