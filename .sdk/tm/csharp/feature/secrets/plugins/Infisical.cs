// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/Infisical.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Infisical, as a voxgig/plugin definition.
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
    /// Infisical.
    ///
    /// <para>`api.token` reads the secret keyed `API_TOKEN` (Infisical's own
    /// convention is environment-style keys) at a secret path in one
    /// environment of a project. Auth is a token, or a universal-auth
    /// (machine identity) login with clientid/clientsecret.</para>
    /// </summary>
    public class InfisicalProvider : IProvider
    {
        private readonly string addr;
        private readonly string token;
        private readonly string clientid;
        private readonly string clientsecret;
        private readonly string project;
        private readonly string environment;
        private readonly string path;

        // A configured token is kept forever; a universal-auth token
        // carries expiresIn and is renewed shortly before it runs out.
        private string livetoken;
        private DateTimeOffset renewat = DateTimeOffset.MaxValue;

        public InfisicalProvider(string addr = null, string token = null, string clientid = null,
            string clientsecret = null, string project = null, string environment = null,
            string path = null)
        {
            this.addr = addr;
            this.token = token;
            this.clientid = clientid;
            this.clientsecret = clientsecret;
            this.project = project;
            this.environment = environment;
            this.path = path;
        }

        private string Login(string useaddr)
        {
            if (!string.IsNullOrEmpty(token))
            {
                return token;
            }

            if (string.IsNullOrEmpty(clientid) || string.IsNullOrEmpty(clientsecret))
            {
                throw new SekretoError("sekreto: infisical: no token and no client credentials");
            }

            var payload = new Dictionary<string, object>
            {
                ["clientId"] = clientid,
                ["clientSecret"] = clientsecret,
            };

            var (status, body) = Http.FetchJson("POST",
                useaddr + "/api/v1/auth/universal-auth/login",
                new Dictionary<string, string> { ["content-type"] = "application/json" },
                Json.Stringify(payload));

            object got = (body as Dictionary<string, object>)?.GetValueOrDefault("accessToken");
            string text = null == got ? null : Convert.ToString(got);

            if (200 != status || string.IsNullOrEmpty(text))
            {
                throw new SekretoError("sekreto: infisical login failed: " + status);
            }

            renewat = Renew.At(
                (body as Dictionary<string, object>)?.GetValueOrDefault("expiresIn"));

            return text;
        }

        public string Lookup(string name)
        {
            string useaddr = (string.IsNullOrEmpty(addr) ? "https://app.infisical.com" : addr)
                .TrimEnd('/');
            Addr.Check(useaddr);

            if (string.IsNullOrEmpty(project) || string.IsNullOrEmpty(environment))
            {
                throw new SekretoError("sekreto: infisical: no project/environment");
            }

            if (null == livetoken || DateTimeOffset.UtcNow >= renewat)
            {
                livetoken = Login(useaddr);
            }

            string url = useaddr + "/api/v3/secrets/raw/" + Names.EnvKey(name)
                + "?workspaceId=" + Url.Encode(project)
                + "&environment=" + Url.Encode(environment)
                + "&secretPath=" + Url.Encode(string.IsNullOrEmpty(path) ? "/" : path);

            var (status, body) = Http.FetchJson("GET", url,
                new Dictionary<string, string> { ["authorization"] = "Bearer " + livetoken });

            if (404 == status)
            {
                return null;
            }

            if (200 != status)
            {
                throw new SekretoError("sekreto: infisical error: " + status);
            }

            object value = ((body as Dictionary<string, object>)?.GetValueOrDefault("secret")
                as Dictionary<string, object>)?.GetValueOrDefault("secretValue");

            return null == value ? null : Convert.ToString(value);
        }

        public string Describe()
        {
            return "infisical:" + (project ?? "") + "/" + (environment ?? "");
        }
    }

    /// <summary>The <c>infisical</c> provider kind.</summary>
    public static class Infisical
    {
        public static readonly Definition Plugin = Providers.ProviderPlugin(
            "infisical", spec => new InfisicalProvider(
                Providers.Text(spec.GetValueOrDefault("addr")),
                Providers.Text(spec.GetValueOrDefault("token")),
                Providers.Text(spec.GetValueOrDefault("clientid")),
                Providers.Text(spec.GetValueOrDefault("clientsecret")),
                Providers.Text(spec.GetValueOrDefault("project")),
                Providers.Text(spec.GetValueOrDefault("environment")),
                Providers.Text(spec.GetValueOrDefault("path"))));
    }
}
