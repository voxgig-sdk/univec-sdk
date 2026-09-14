// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/Hashicorp.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// HashiCorp Vault, as a voxgig/plugin definition.
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
    /// HashiCorp Vault.
    ///
    /// <para>KV v2 (the default): `api.token` reads
    /// `{addr}/v1/{mount}/data/api` and takes the `token` field of
    /// `data.data`. KV v1 (`kv: 1`) reads `{addr}/v1/{mount}/api` and takes
    /// the field of `data`. A 404 means "not here" - a miss - so a vault can
    /// sit in a chain with fallbacks.</para>
    ///
    /// <para>A Vault Enterprise namespace rides the X-Vault-Namespace
    /// header, on logins as well as reads.</para>
    ///
    /// <para>Instead of being handed a token, the provider can log in:
    /// Kubernetes auth (the pod's service-account JWT, from its conventional
    /// path) or AppRole. A failed login is an error, never a miss - it means
    /// this store could not answer at all.</para>
    /// </summary>
    public class HashicorpProvider : IProvider
    {
        private readonly string addr;
        private readonly string mount;
        private readonly int kv;
        private readonly string vaultnamespace;
        private readonly Dictionary<string, object> auth;

        // The working token: a configured token is kept forever, a logged-in
        // token is renewed shortly before its lease runs out - a
        // long-running process must not keep presenting a token the vault
        // already expired.
        private string livetoken;
        private DateTimeOffset renewat = DateTimeOffset.MaxValue;

        public HashicorpProvider(string addr, string token, string mount = null, int kv = 0,
            string vaultnamespace = null, Dictionary<string, object> auth = null)
        {
            this.addr = addr ?? "";
            this.mount = string.IsNullOrEmpty(mount) ? "secret" : mount;
            this.kv = 0 == kv ? 2 : kv;

            // A version typo like kv: 3 must not quietly behave as v2 and
            // turn its 404s into misses; there is nothing safe to assume it
            // meant.
            if (1 != this.kv && 2 != this.kv)
            {
                throw new SekretoError(
                    "sekreto: hashicorp: unsupported kv version: " + this.kv);
            }

            this.vaultnamespace = vaultnamespace;
            this.auth = auth;
            this.livetoken = string.IsNullOrEmpty(token) ? null : token;
        }

        private Dictionary<string, string> BaseHeaders()
        {
            var headers = new Dictionary<string, string>();

            if (!string.IsNullOrEmpty(vaultnamespace))
            {
                headers["X-Vault-Namespace"] = vaultnamespace;
            }

            return headers;
        }

        private string Login()
        {
            if (null == auth)
            {
                throw new SekretoError("sekreto: hashicorp: no token and no auth method");
            }

            string method = Providers.Text(auth.GetValueOrDefault("method"));
            string authmount = Providers.Text(auth.GetValueOrDefault("mount"));
            if (string.IsNullOrEmpty(authmount))
            {
                authmount = method;
            }

            string url = addr.TrimEnd('/') + "/v1/auth/" + authmount + "/login";

            var body = new Dictionary<string, object>();

            if ("kubernetes" == method)
            {
                string jwt = Providers.Text(auth.GetValueOrDefault("jwt"));

                if (null == jwt)
                {
                    string file = Providers.Text(auth.GetValueOrDefault("jwtfile"));
                    if (string.IsNullOrEmpty(file))
                    {
                        file = "/var/run/secrets/kubernetes.io/serviceaccount/token";
                    }

                    try
                    {
                        jwt = File.ReadAllText(file).Trim();
                    }
                    catch (Exception)
                    {
                        throw new SekretoError("sekreto: hashicorp: cannot read jwt file " + file);
                    }
                }

                body["role"] = Providers.Text(auth.GetValueOrDefault("role")) ?? "";
                body["jwt"] = jwt;
            }
            else if ("approle" == method)
            {
                body["role_id"] = Providers.Text(auth.GetValueOrDefault("roleid")) ?? "";
                body["secret_id"] = Providers.Text(auth.GetValueOrDefault("secretid")) ?? "";
            }
            else
            {
                throw new SekretoError(
                    "sekreto: hashicorp: unknown auth method: " + (method ?? ""));
            }

            var (status, resbody) = Http.FetchJson("POST", url, BaseHeaders(), Json.Stringify(body));

            var authbody = (resbody as Dictionary<string, object>)?.GetValueOrDefault("auth")
                as Dictionary<string, object>;
            object got = authbody?.GetValueOrDefault("client_token");
            string token = null == got ? null : Convert.ToString(got);

            if (200 != status || string.IsNullOrEmpty(token))
            {
                throw new SekretoError("sekreto: hashicorp login failed: " + status + ": " + url);
            }

            renewat = Renew.At(authbody.GetValueOrDefault("lease_duration"));

            return token;
        }

        public string Lookup(string name)
        {
            Addr.Check(addr);

            if (null == livetoken || DateTimeOffset.UtcNow >= renewat)
            {
                livetoken = Login();
            }

            Dictionary<string, object> reference = Names.VaultRef(name);
            string basepath = addr.TrimEnd('/') + "/v1/" + mount;
            string url = 1 == kv
                ? basepath + "/" + reference["path"]
                : basepath + "/data/" + reference["path"];

            var headers = BaseHeaders();
            headers["X-Vault-Token"] = livetoken;

            var (status, body) = Http.FetchJson("GET", url, headers);

            if (404 == status)
            {
                return null;
            }

            if (200 != status)
            {
                throw new SekretoError("sekreto: hashicorp error: " + status + ": " + url);
            }

            object outer = (body as Dictionary<string, object>)?.GetValueOrDefault("data");

            object data = 1 == kv
                ? outer
                : (outer as Dictionary<string, object>)?.GetValueOrDefault("data");

            object value = (data as Dictionary<string, object>)?
                .GetValueOrDefault((string)reference["field"]);

            return null == value ? null : Convert.ToString(value);
        }

        public string Describe()
        {
            return "hashicorp:" + addr + "/" + mount;
        }
    }

    /// <summary>The <c>hashicorp</c> provider kind.</summary>
    public static class Hashicorp
    {
        public static readonly Definition Plugin = Providers.ProviderPlugin(
            "hashicorp", spec => new HashicorpProvider(
                Providers.TextOr(spec.GetValueOrDefault("addr"), ""),
                Providers.TextOr(spec.GetValueOrDefault("token"), ""),
                Providers.Text(spec.GetValueOrDefault("mount")),
                null == spec.GetValueOrDefault("kv")
                    ? 0
                    : Convert.ToInt32(spec.GetValueOrDefault("kv"), CultureInfo.InvariantCulture),
                Providers.Text(spec.GetValueOrDefault("vaultnamespace")),
                spec.GetValueOrDefault("auth") as Dictionary<string, object>));
    }
}
