// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/SecretSpec.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// SecretSpec, as a voxgig/plugin definition.
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
    /// SecretSpec (https://secretspec.dev).
    ///
    /// <para>SecretSpec is a declaration - a `secretspec.toml` naming the
    /// secrets a project needs - plus a chain of its own backends to satisfy
    /// them from. That makes it the same shape as sekreto one level down, and
    /// the reason to support it is the same reason sekreto exists: a project
    /// that has already declared its secrets there should not have to declare
    /// them again here.</para>
    ///
    /// <para>Read through its CLI, as boru is, because that is the interface
    /// it offers a program in another language: `secretspec get API_TOKEN`
    /// prints the value on stdout and nothing else. A sekreto name maps to a
    /// SecretSpec key exactly as it maps to an environment variable -
    /// `api.token` is `API_TOKEN` - which is the convention SecretSpec's own
    /// examples use.</para>
    ///
    /// <para>backend selects one of SecretSpec's backends (`--provider`, e.g.
    /// `keyring` or `dotenv://.env`) and is called backend here only because
    /// `provider` already means something else in this library.</para>
    ///
    /// <para>A reason is required, not optional: SecretSpec records every
    /// read in an audit log and refuses to read at all without one. sekreto
    /// sends `sekreto` unless told otherwise, so the audit trail says which
    /// tool asked.</para>
    /// </summary>
    public class SecretSpecProvider : IProvider
    {
        private readonly string command;
        private readonly string file;
        private readonly string profile;
        private readonly string backend;
        private readonly string reason;
        private readonly string prefix;

        public SecretSpecProvider(string command = null, string file = null,
            string profile = null, string backend = null, string reason = null,
            string prefix = null)
        {
            this.command = string.IsNullOrEmpty(command) ? "secretspec" : command;
            this.file = file;
            this.profile = profile;
            this.backend = backend;
            this.reason = reason;
            this.prefix = prefix;
        }

        public string Lookup(string name)
        {
            string key = Names.EnvKey(name, prefix);

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

            // Arguments are passed one by one, never through a shell.
            if (!string.IsNullOrEmpty(file))
            {
                start.ArgumentList.Add("--file");
                start.ArgumentList.Add(file);
            }

            start.ArgumentList.Add("get");
            start.ArgumentList.Add(key);

            if (!string.IsNullOrEmpty(backend))
            {
                start.ArgumentList.Add("--provider");
                start.ArgumentList.Add(backend);
            }

            if (!string.IsNullOrEmpty(profile))
            {
                start.ArgumentList.Add("--profile");
                start.ArgumentList.Add(profile);
            }

            start.ArgumentList.Add("--reason");
            start.ArgumentList.Add(string.IsNullOrEmpty(reason) ? "sekreto" : reason);

            Ran ran = Child.Run(start, command);
            string outtext = ran.Out;
            string why = ran.Why;
            int status = ran.Status;

            if (0 == status)
            {
                // The value and one newline, and nothing else.
                return outtext.EndsWith("\n", StringComparison.Ordinal)
                    ? outtext.Substring(0, outtext.Length - 1)
                    : outtext;
            }

            if (SecretSpecMiss(why, key))
            {
                return null;
            }

            throw new SekretoError(
                "sekreto: secretspec error: " + (0 == why.Length ? "exit " + status : why));
        }

        public string Describe()
        {
            return "secretspec" + (string.IsNullOrEmpty(backend) ? "" : ":" + backend);
        }

        /// <summary>
        /// Does this SecretSpec failure mean "no such secret" rather than "I
        /// could not answer"?
        ///
        /// <para>SecretSpec says `Secret 'API_TOKEN' not found` for both a
        /// name it does not declare and one declared with no value, and both
        /// are misses: this store does not hold it, so the chain carries
        /// on.</para>
        ///
        /// <para>MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec
        /// also says `Provider backend 'keyring' not found`, which is a store
        /// that could not answer at all - and reading that as a miss is the
        /// worst failure this library has, because the chain then falls
        /// through to a weaker store without saying so. The key is required
        /// to appear, so the two cannot be confused.</para>
        /// </summary>
        internal static bool SecretSpecMiss(string why, string key)
        {
            return why.Contains("Secret '" + key + "' not found");
        }
    }

    /// <summary>The <c>secretspec</c> provider kind.</summary>
    public static class SecretSpec
    {
        public static readonly Definition Plugin = Providers.ProviderPlugin(
            "secretspec", spec => new SecretSpecProvider(
                Providers.Text(spec.GetValueOrDefault("command")),
                Providers.Text(spec.GetValueOrDefault("file")),
                Providers.Text(spec.GetValueOrDefault("profile")),
                Providers.Text(spec.GetValueOrDefault("backend")),
                Providers.Text(spec.GetValueOrDefault("reason")),
                Providers.Text(spec.GetValueOrDefault("prefix"))));
    }
}
