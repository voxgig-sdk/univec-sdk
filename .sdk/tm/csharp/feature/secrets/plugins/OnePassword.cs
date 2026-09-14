// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/OnePassword.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// 1Password Connect, as a voxgig/plugin definition.
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
    /// 1Password, through a Connect server.
    ///
    /// <para>The item titled `api.token` (titles keep their dots), in the
    /// named vault. The value is the field with purpose PASSWORD, or the
    /// field labelled `value`. A vault that cannot be found is an error -
    /// config names it, so its absence is a broken store, not a missing
    /// secret.</para>
    /// </summary>
    public class OnePasswordProvider : IProvider
    {
        private readonly string addr;
        private readonly string token;
        private readonly string vault;

        private string vaultid;

        public OnePasswordProvider(string addr = null, string token = null, string vault = null)
        {
            this.addr = addr;
            this.token = token;
            this.vault = vault;
        }

        private Dictionary<string, string> Auth()
        {
            return new Dictionary<string, string>
            {
                ["authorization"] = "Bearer " + (token ?? ""),
            };
        }

        private string ResolveVault(string useaddr)
        {
            string want = vault ?? "";
            if ("" == want)
            {
                throw new SekretoError("sekreto: onepassword: no vault");
            }

            var (status, body) = Http.FetchJson("GET", useaddr + "/v1/vaults", Auth());

            if (200 != status || !(body is List<object> listing))
            {
                throw new SekretoError("sekreto: onepassword error: " + status + ": listing vaults");
            }

            foreach (object entry in listing)
            {
                if (entry is Dictionary<string, object> found)
                {
                    object id = found.GetValueOrDefault("id");
                    if (want.Equals(id) || want.Equals(found.GetValueOrDefault("name")))
                    {
                        return Convert.ToString(id);
                    }
                }
            }

            throw new SekretoError("sekreto: onepassword: no vault named " + want);
        }

        public string Lookup(string name)
        {
            Names.CheckName(name);

            string useaddr = (addr ?? "").TrimEnd('/');
            if ("" == useaddr)
            {
                throw new SekretoError("sekreto: onepassword: no addr");
            }
            Addr.Check(useaddr);

            if (null == vaultid)
            {
                vaultid = ResolveVault(useaddr);
            }

            string filter = Url.Encode("title eq \"" + name + "\"");

            var (foundstatus, foundbody) = Http.FetchJson("GET",
                useaddr + "/v1/vaults/" + vaultid + "/items?filter=" + filter, Auth());

            if (200 != foundstatus || !(foundbody is List<object> matches))
            {
                throw new SekretoError(
                    "sekreto: onepassword error: " + foundstatus + ": finding " + name);
            }

            if (0 == matches.Count)
            {
                return null;
            }

            string itemid = Convert.ToString(
                (matches[0] as Dictionary<string, object>)?.GetValueOrDefault("id"));

            var (itemstatus, itembody) = Http.FetchJson("GET",
                useaddr + "/v1/vaults/" + vaultid + "/items/" + itemid, Auth());

            if (200 != itemstatus)
            {
                throw new SekretoError(
                    "sekreto: onepassword error: " + itemstatus + ": reading " + name);
            }

            var fields = (itembody as Dictionary<string, object>)?.GetValueOrDefault("fields")
                as List<object> ?? new List<object>();

            foreach (object entry in fields)
            {
                if (entry is Dictionary<string, object> field
                    && "PASSWORD".Equals(field.GetValueOrDefault("purpose")))
                {
                    object value = field.GetValueOrDefault("value");
                    return null == value ? null : Convert.ToString(value);
                }
            }
            foreach (object entry in fields)
            {
                if (entry is Dictionary<string, object> field
                    && "value".Equals(field.GetValueOrDefault("label")))
                {
                    object value = field.GetValueOrDefault("value");
                    return null == value ? null : Convert.ToString(value);
                }
            }

            return null;
        }

        public string Describe()
        {
            return "onepassword:" + (vault ?? "");
        }
    }

    /// <summary>The <c>onepassword</c> provider kind.</summary>
    public static class OnePassword
    {
        public static readonly Definition Plugin = Providers.ProviderPlugin(
            "onepassword", spec => new OnePasswordProvider(
                Providers.Text(spec.GetValueOrDefault("addr")),
                Providers.Text(spec.GetValueOrDefault("token")),
                Providers.Text(spec.GetValueOrDefault("vault"))));
    }
}
