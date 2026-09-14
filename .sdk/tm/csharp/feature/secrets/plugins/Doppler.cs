// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/Doppler.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Doppler, as a voxgig/plugin definition.
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
    /// Doppler.
    ///
    /// <para>The whole config is downloaded once - Doppler's own bulk
    /// endpoint - and answered from memory, like a remote .env: `api.token`
    /// is the `API_TOKEN` entry. A service token is config-scoped, so
    /// project and config are only needed with broader tokens.</para>
    /// </summary>
    public class DopplerProvider : IProvider
    {
        private readonly string token;
        private readonly string project;
        private readonly string config;
        private readonly string addr;

        private Dictionary<string, string> values;

        public DopplerProvider(string token = null, string project = null,
            string config = null, string addr = null)
        {
            this.token = token;
            this.project = project;
            this.config = config;
            this.addr = addr;
        }

        private Dictionary<string, string> Load()
        {
            if (null != values)
            {
                return values;
            }

            string useaddr = (string.IsNullOrEmpty(addr) ? "https://api.doppler.com" : addr)
                .TrimEnd('/');
            Addr.Check(useaddr);

            string url = useaddr + "/v3/configs/config/secrets/download?format=json";
            if (!string.IsNullOrEmpty(project))
            {
                url += "&project=" + Url.Encode(project);
            }
            if (!string.IsNullOrEmpty(config))
            {
                url += "&config=" + Url.Encode(config);
            }

            var (status, body) = Http.FetchJson("GET", url,
                new Dictionary<string, string> { ["authorization"] = "Bearer " + (token ?? "") });

            if (200 != status || !(body is Dictionary<string, object> entries))
            {
                throw new SekretoError("sekreto: doppler error: " + status);
            }

            values = new Dictionary<string, string>();
            foreach (var entry in entries)
            {
                if (null != entry.Value)
                {
                    values[entry.Key] = Convert.ToString(entry.Value);
                }
            }

            return values;
        }

        public string Lookup(string name)
        {
            return Load().TryGetValue(Names.EnvKey(name), out string found) ? found : null;
        }

        public string Describe()
        {
            return "doppler"
                + (string.IsNullOrEmpty(project) ? "" : ":" + project + "/" + (config ?? ""));
        }
    }

    /// <summary>The <c>doppler</c> provider kind.</summary>
    public static class Doppler
    {
        public static readonly Definition Plugin = Providers.ProviderPlugin(
            "doppler", spec => new DopplerProvider(
                Providers.Text(spec.GetValueOrDefault("token")),
                Providers.Text(spec.GetValueOrDefault("project")),
                Providers.Text(spec.GetValueOrDefault("config")),
                Providers.Text(spec.GetValueOrDefault("addr"))));
    }
}
