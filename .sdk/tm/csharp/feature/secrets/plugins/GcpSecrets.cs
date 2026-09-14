// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/GcpSecrets.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// GCP Secret Manager, as a voxgig/plugin definition.
//
// PLUGIN CODE. This file is in the VoxgigSekretoPlugins assembly, which
// the core does not reference - so nothing here is linked into an
// application whose chain names only built-in kinds. See
// docs/design/plugin-providers.md.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Text;

using Definition = Voxgig.Plugin.Definition;

namespace Voxgig.Sekreto.Plugins
{
    /// <summary>
    /// GCP Secret Manager.
    ///
    /// <para>`api.token` reads secret `api_token` (dots flattened to `_`;
    /// Secret Manager ids have no hierarchy and reject dots), latest
    /// version. The token comes from config, then
    /// GOOGLE_OAUTH_ACCESS_TOKEN, then the GCE/GKE metadata server - so on
    /// Google's own platform no credential configuration is needed at
    /// all.</para>
    ///
    /// <para>The metadata call itself is plain http to a link-local host by
    /// platform design; no credential rides on it, so Addr.Check guards the
    /// Secret Manager address instead.</para>
    /// </summary>
    public class GcpSecretsProvider : IProvider
    {
        private readonly string project;
        private readonly string token;
        private readonly string addr;
        private readonly string metadataaddr;

        // A configured token is kept forever; a metadata-server token
        // carries expires_in and is renewed shortly before it runs out.
        private string livetoken;
        private DateTimeOffset renewat = DateTimeOffset.MaxValue;

        public GcpSecretsProvider(string project = null, string token = null,
            string addr = null, string metadataaddr = null)
        {
            this.project = project;
            this.token = token;
            this.addr = addr;
            this.metadataaddr = metadataaddr;
        }

        private string MetadataAddr()
        {
            if (!string.IsNullOrEmpty(metadataaddr))
            {
                return metadataaddr;
            }

            string host = Environment.GetEnvironmentVariable("GCE_METADATA_HOST");
            return string.IsNullOrEmpty(host) ? "http://metadata.google.internal" : "http://" + host;
        }

        private string Login()
        {
            string configured = token;
            if (string.IsNullOrEmpty(configured))
            {
                configured = Environment.GetEnvironmentVariable("GOOGLE_OAUTH_ACCESS_TOKEN");
            }
            if (!string.IsNullOrEmpty(configured))
            {
                return configured;
            }

            string url = MetadataAddr().TrimEnd('/')
                + "/computeMetadata/v1/instance/service-accounts/default/token";

            var (status, body) = Http.FetchJson("GET", url,
                new Dictionary<string, string> { ["Metadata-Flavor"] = "Google" });

            object got = (body as Dictionary<string, object>)?.GetValueOrDefault("access_token");
            string text = null == got ? null : Convert.ToString(got);

            if (200 != status || string.IsNullOrEmpty(text))
            {
                throw new SekretoError("sekreto: gcp: no token and metadata server did not answer");
            }

            renewat = Renew.At(
                (body as Dictionary<string, object>)?.GetValueOrDefault("expires_in"));

            return text;
        }

        public string Lookup(string name)
        {
            if (string.IsNullOrEmpty(project))
            {
                throw new SekretoError("sekreto: gcp: no project");
            }

            string useaddr = string.IsNullOrEmpty(addr) ? "https://secretmanager.googleapis.com" : addr;
            Addr.Check(useaddr);

            if (null == livetoken || DateTimeOffset.UtcNow >= renewat)
            {
                livetoken = Login();
            }

            string url = useaddr.TrimEnd('/') + "/v1/projects/" + project + "/secrets/"
                + Names.FlatName(name, "_") + "/versions/latest:access";

            var (status, body) = Http.FetchJson("GET", url,
                new Dictionary<string, string> { ["authorization"] = "Bearer " + livetoken });

            if (404 == status)
            {
                return null;
            }

            if (200 != status)
            {
                throw new SekretoError("sekreto: gcp error: " + status + ": " + url);
            }

            object data = ((body as Dictionary<string, object>)?.GetValueOrDefault("payload")
                as Dictionary<string, object>)?.GetValueOrDefault("data");

            if (!(data is string encoded))
            {
                return null;
            }

            // See the aws provider: an undecodable payload is a SekretoError.
            try
            {
                return Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
            }
            catch (FormatException)
            {
                throw new SekretoError("sekreto: gcp: undecodable secret");
            }
        }

        public string Describe()
        {
            return "gcpsecrets:" + (project ?? "");
        }
    }

    /// <summary>The <c>gcpsecrets</c> provider kind.</summary>
    public static class GcpSecrets
    {
        public static readonly Definition Plugin = Providers.ProviderPlugin(
            "gcpsecrets", spec => new GcpSecretsProvider(
                Providers.Text(spec.GetValueOrDefault("project")),
                Providers.Text(spec.GetValueOrDefault("token")),
                Providers.Text(spec.GetValueOrDefault("addr")),
                Providers.Text(spec.GetValueOrDefault("metadataaddr"))));
    }
}
