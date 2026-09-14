// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/Boru.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The boru vault, as a voxgig/plugin definition.
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
    /// A boru vault (https://github.com/boru-lang/boru).
    ///
    /// <para>Two ways in, both boru's own.</para>
    ///
    /// <para>With no addr, the CLI: `boru vault get --reveal &lt;alias&gt;`
    /// prints the secret on stdout and nothing else. The passphrase is read
    /// by boru itself from BORU_VAULT_PASSPHRASE; sekreto never accepts it
    /// as config and never puts it on a command line, where it would show up
    /// in the process table.</para>
    ///
    /// <para>With an addr, boru's wire protocol: `boru vault serve`
    /// publishes a read-only, HashiCorp-shaped provision API (boru's
    /// design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
    /// from `boru vault grant`. A sekreto name is already a valid boru
    /// alias, and boru aliases keep their dots, so `api.token` is the single
    /// path segment `api.token` - not the `api`/`token` split a HashiCorp KV
    /// gets. The value is the `value` field. A 404 is a miss; anything else
    /// the server refuses (a revoked capability, a sealed vault) is an
    /// error.</para>
    ///
    /// <para>boru's `vault proxy` and `vault mcp` remain out of bounds: they
    /// are a credential *broker*, built precisely so the caller never
    /// receives the credential. `vault serve` is the provision endpoint,
    /// built to hand the value back - that is the one sekreto uses.</para>
    /// </summary>
    public class BoruProvider : IProvider
    {
        private readonly string command;
        private readonly string namespace_;
        private readonly string home;
        private readonly string addr;
        private readonly string token;
        private readonly string mount;

        public BoruProvider(string command, string namespace_ = null, string home = null,
            string addr = null, string token = null, string mount = null)
        {
            this.command = string.IsNullOrEmpty(command) ? "boru" : command;
            this.namespace_ = namespace_;
            this.home = home;
            this.addr = string.IsNullOrEmpty(addr) ? null : addr.TrimEnd('/');
            this.token = token;
            this.mount = string.IsNullOrEmpty(mount) ? "secret" : mount;
        }

        public string Lookup(string name)
        {
            Names.CheckName(name);

            if (null != addr)
            {
                return WireLookup(name);
            }

            string alias = string.IsNullOrEmpty(namespace_) ? name : namespace_ + ":" + name;

            var start = new ProcessStartInfo
            {
                FileName = command,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                // Redirected so it can be CLOSED: an inherited stdin lets a
                // CLI that prompts for a passphrase block on the parent's
                // console forever.
                RedirectStandardInput = true,
                UseShellExecute = false,
            };

            // Arguments are passed one by one, never through a shell, so an
            // alias is never word-split or interpreted.
            start.ArgumentList.Add("vault");
            start.ArgumentList.Add("get");
            start.ArgumentList.Add("--reveal");
            start.ArgumentList.Add(alias);

            if (!string.IsNullOrEmpty(home))
            {
                start.Environment["BORU_HOME"] = home;
            }

            Ran ran = Child.Run(start, command);
            string outtext = ran.Out;
            string why = ran.Why;
            int status = ran.Status;

            if (0 == status)
            {
                // boru prints the value and one newline, and nothing else.
                return outtext.EndsWith("\n", StringComparison.Ordinal)
                    ? outtext.Substring(0, outtext.Length - 1)
                    : outtext;
            }

            // "no alias named" is boru saying it does not hold this secret,
            // which is a miss: the chain carries on to the next provider. A
            // locked vault or a wrong passphrase is not a miss - treating it
            // as one would fall through to a weaker store without saying so.
            if (BoruMiss(why))
            {
                return null;
            }

            throw new SekretoError(
                "sekreto: boru vault error: " + (0 == why.Length ? "exit " + status : why));
        }

        private string WireLookup(string name)
        {
            Addr.Check(addr);

            // The DOTTED name stays one segment: boru aliases keep their
            // dots, so there is no vaultref split here.
            string alias = string.IsNullOrEmpty(namespace_) ? name : namespace_ + "/" + name;
            string url = addr + "/v1/" + mount + "/data/" + alias;

            var (status, body) = Http.FetchJson("GET", url,
                new Dictionary<string, string> { ["X-Vault-Token"] = token ?? "" });

            if (404 == status)
            {
                return null;
            }

            if (200 != status)
            {
                throw new SekretoError("sekreto: boru serve error: " + status + ": " + url);
            }

            object data = ((body as Dictionary<string, object>)?.GetValueOrDefault("data")
                as Dictionary<string, object>)?.GetValueOrDefault("data");

            object value = (data as Dictionary<string, object>)?.GetValueOrDefault("value");

            return null == value ? null : Convert.ToString(value);
        }

        public string Describe()
        {
            if (null != addr)
            {
                return "boru:" + addr;
            }

            return "boru" + (string.IsNullOrEmpty(namespace_) ? "" : ":" + namespace_);
        }

        /// <summary>
        /// Does this boru failure mean "no such secret" rather than "I could
        /// not answer"? Matched on boru's own wording for a missing alias.
        /// </summary>
        internal static bool BoruMiss(string why)
        {
            return why.Contains("no alias named");
        }
    }

    /// <summary>The <c>boru</c> provider kind.</summary>
    public static class Boru
    {
        public static readonly Definition Plugin = Providers.ProviderPlugin(
            "boru", spec => new BoruProvider(
                Providers.Text(spec.GetValueOrDefault("command")),
                Providers.Text(spec.GetValueOrDefault("namespace")),
                Providers.Text(spec.GetValueOrDefault("home")),
                Providers.Text(spec.GetValueOrDefault("addr")),
                Providers.Text(spec.GetValueOrDefault("token")),
                Providers.Text(spec.GetValueOrDefault("mount"))));
    }
}
