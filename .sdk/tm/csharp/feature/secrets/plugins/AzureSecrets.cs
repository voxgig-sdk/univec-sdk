// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/AzureSecrets.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Azure Key Vault, as a voxgig/plugin definition.
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
    /// Azure Key Vault.
    ///
    /// <para>`api.token` reads secret `api-token` (dots flattened to `-`;
    /// Key Vault names allow nothing else), current version. The token comes
    /// from config, then a client-credentials login when
    /// tenant/clientid/clientsecret are given, then the IMDS
    /// managed-identity endpoint - so on Azure's own platform no credential
    /// configuration is needed.</para>
    ///
    /// <para>As with GCP, the IMDS call is plain http to a link-local host
    /// by platform design and carries no credential; the login and vault
    /// addresses are Addr.Check-guarded.</para>
    /// </summary>
    public class AzureSecretsProvider : IProvider
    {
        private const string Resource = "https://vault.azure.net";

        private readonly string vault;
        private readonly string token;
        private readonly string tenant;
        private readonly string clientid;
        private readonly string clientsecret;
        private readonly string loginaddr;
        private readonly string imdsaddr;
        private readonly string apiversion;

        // A configured token is kept forever; logged-in and IMDS tokens
        // carry expires_in and are renewed shortly before they run out.
        private string livetoken;
        private DateTimeOffset renewat = DateTimeOffset.MaxValue;

        public AzureSecretsProvider(string vault = null, string token = null, string tenant = null,
            string clientid = null, string clientsecret = null, string loginaddr = null,
            string imdsaddr = null, string apiversion = null)
        {
            this.vault = vault;
            this.token = token;
            this.tenant = tenant;
            this.clientid = clientid;
            this.clientsecret = clientsecret;
            this.loginaddr = loginaddr;
            this.imdsaddr = imdsaddr;
            this.apiversion = apiversion;
        }

        private string Login()
        {
            if (!string.IsNullOrEmpty(token))
            {
                return token;
            }

            if (!string.IsNullOrEmpty(tenant) && !string.IsNullOrEmpty(clientid)
                && !string.IsNullOrEmpty(clientsecret))
            {
                string uselogin = string.IsNullOrEmpty(loginaddr)
                    ? "https://login.microsoftonline.com"
                    : loginaddr;
                Addr.Check(uselogin);

                string url = uselogin.TrimEnd('/') + "/" + tenant + "/oauth2/v2.0/token";
                string form = "grant_type=client_credentials&client_id=" + Url.Encode(clientid)
                    + "&client_secret=" + Url.Encode(clientsecret)
                    + "&scope=" + Url.Encode(Resource + "/.default");

                var (status, body) = Http.FetchJson("POST", url,
                    new Dictionary<string, string>
                    {
                        ["content-type"] = "application/x-www-form-urlencoded",
                    },
                    form);

                object got = (body as Dictionary<string, object>)?.GetValueOrDefault("access_token");
                string text = null == got ? null : Convert.ToString(got);

                if (200 != status || string.IsNullOrEmpty(text))
                {
                    throw new SekretoError("sekreto: azure login failed: " + status);
                }

                renewat = Renew.At(
                    (body as Dictionary<string, object>)?.GetValueOrDefault("expires_in"));

                return text;
            }

            string imds = (string.IsNullOrEmpty(imdsaddr) ? "http://169.254.169.254" : imdsaddr)
                .TrimEnd('/')
                + "/metadata/identity/oauth2/token?api-version=2018-02-01&resource="
                + Url.Encode(Resource);

            var (imdsstatus, imdsbody) = Http.FetchJson("GET", imds,
                new Dictionary<string, string> { ["Metadata"] = "true" });

            object found = (imdsbody as Dictionary<string, object>)?.GetValueOrDefault("access_token");
            string foundtext = null == found ? null : Convert.ToString(found);

            if (200 != imdsstatus || string.IsNullOrEmpty(foundtext))
            {
                throw new SekretoError(
                    "sekreto: azure: no token, no client credentials, and IMDS did not answer");
            }

            renewat = Renew.At(
                (imdsbody as Dictionary<string, object>)?.GetValueOrDefault("expires_in"));

            return foundtext;
        }

        public string Lookup(string name)
        {
            if (string.IsNullOrEmpty(vault))
            {
                throw new SekretoError("sekreto: azure: no vault");
            }

            // Only an explicit scheme is a URL; a vault NAMED httpvault must
            // still become https://httpvault.vault.azure.net.
            string vaulturl = vault.StartsWith("http://", StringComparison.Ordinal)
                || vault.StartsWith("https://", StringComparison.Ordinal)
                ? vault
                : "https://" + vault + ".vault.azure.net";
            Addr.Check(vaulturl);

            if (null == livetoken || DateTimeOffset.UtcNow >= renewat)
            {
                livetoken = Login();
            }

            string url = vaulturl.TrimEnd('/') + "/secrets/" + Names.FlatName(name, "-")
                + "?api-version=" + (string.IsNullOrEmpty(apiversion) ? "7.4" : apiversion);

            var (status, body) = Http.FetchJson("GET", url,
                new Dictionary<string, string> { ["authorization"] = "Bearer " + livetoken });

            if (404 == status)
            {
                return null;
            }

            if (200 != status)
            {
                throw new SekretoError(
                    "sekreto: azure error: " + status + ": " + url.Split('?')[0]);
            }

            object value = (body as Dictionary<string, object>)?.GetValueOrDefault("value");

            return null == value ? null : Convert.ToString(value);
        }

        public string Describe()
        {
            return "azuresecrets:" + (vault ?? "");
        }
    }

    /// <summary>The <c>azuresecrets</c> provider kind.</summary>
    public static class AzureSecrets
    {
        public static readonly Definition Plugin = Providers.ProviderPlugin(
            "azuresecrets", spec => new AzureSecretsProvider(
                Providers.Text(spec.GetValueOrDefault("vault")),
                Providers.Text(spec.GetValueOrDefault("token")),
                Providers.Text(spec.GetValueOrDefault("tenant")),
                Providers.Text(spec.GetValueOrDefault("clientid")),
                Providers.Text(spec.GetValueOrDefault("clientsecret")),
                Providers.Text(spec.GetValueOrDefault("loginaddr")),
                Providers.Text(spec.GetValueOrDefault("imdsaddr")),
                Providers.Text(spec.GetValueOrDefault("apiversion"))));
    }
}
