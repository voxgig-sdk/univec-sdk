// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/src/Providers.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The four BUILT-IN provider kinds, and what a provider is.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or null to mean "ask the next one". Nothing else about a
// provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.
//
// Two failure shapes, and they are never interchangeable. A store that
// does not hold the secret is a MISS (null) - the chain carries on. A
// store that could not answer - bad credentials, unreachable host,
// missing configuration - is an ERROR: falling through there would
// quietly reach for a weaker store.
//
// WHAT IS IN THIS FILE AND WHAT IS NOT. The line is "reads at most a
// local file": env, memory, dotenv and file are built in, and this
// assembly - VoxgigSekreto - links nothing that opens a socket, signs a
// request or spawns a process. Every other kind is a voxgig/plugin
// definition in the SEPARATE VoxgigSekretoPlugins assembly under
// plugins/, which references this one and is never referenced back. A
// core that cannot name the plugins assembly cannot reach it, whatever
// anyone later writes here.
//
// A port of typescript/src/provider/, which is canonical.

using System;
using System.Collections.Generic;
using System.IO;

using Voxgig.Plugin;

namespace Voxgig.Sekreto
{
    /// <summary>A source of secrets.</summary>
    public interface IProvider
    {
        /// <summary>The value, or null if this provider does not have it.</summary>
        string Lookup(string name);

        /// <summary>A short description, shown by `Sekreto.Sources()`.</summary>
        string Describe();
    }

    /// <summary>Environment variables: `api.token` from `API_TOKEN`.</summary>
    public class EnvProvider : IProvider
    {
        private readonly string prefix;
        private readonly Dictionary<string, object> source;

        public EnvProvider(string prefix = null, Dictionary<string, object> source = null)
        {
            this.prefix = prefix;
            this.source = source;
        }

        public string Lookup(string name)
        {
            string key = Names.EnvKey(name, prefix);

            if (null != source)
            {
                return source.TryGetValue(key, out object found) && null != found
                    ? Convert.ToString(found)
                    : null;
            }

            return Environment.GetEnvironmentVariable(key);
        }

        public string Describe()
        {
            return "env" + (string.IsNullOrEmpty(prefix) ? "" : ":" + prefix);
        }
    }

    /// <summary>A `.env` file, read once, keyed exactly like the environment.</summary>
    public class DotenvProvider : IProvider
    {
        private readonly string file;
        private readonly string prefix;
        private Dictionary<string, object> values;

        public DotenvProvider(string file, string prefix = null)
        {
            this.file = file;
            this.prefix = prefix;
        }

        private Dictionary<string, object> Load()
        {
            if (null == values)
            {
                try
                {
                    values = Dotenv.Parse(File.ReadAllText(file));
                }
                catch (FileNotFoundException)
                {
                    // An absent file - or an absent directory - means "no
                    // secrets here", exactly like FileProvider. Anything else
                    // (permission denied, an unreadable mount) is a store
                    // that could not answer, and swallowing it would fall
                    // through to a weaker store.
                    values = new Dictionary<string, object>();
                }
                catch (DirectoryNotFoundException)
                {
                    values = new Dictionary<string, object>();
                }
                catch (Exception err)
                {
                    throw new SekretoError(
                        "sekreto: dotenv provider cannot read " + file + ": " + err.Message);
                }
            }

            return values;
        }

        public string Lookup(string name)
        {
            return Load().TryGetValue(Names.EnvKey(name, prefix), out object found) && null != found
                ? Convert.ToString(found)
                : null;
        }

        public string Describe()
        {
            return "dotenv:" + file;
        }
    }

    /// <summary>
    /// Literal values, keyed like environment variables. The spec uses this
    /// to test chain behaviour without touching the outside world.
    /// </summary>
    public class MemoryProvider : IProvider
    {
        private readonly Dictionary<string, object> values;
        private readonly string prefix;

        public MemoryProvider(Dictionary<string, object> values, string prefix = null)
        {
            this.values = values ?? new Dictionary<string, object>();
            this.prefix = prefix;
        }

        public string Lookup(string name)
        {
            return values.TryGetValue(Names.EnvKey(name, prefix), out object found) && null != found
                ? Convert.ToString(found)
                : null;
        }

        public string Describe()
        {
            return "memory" + (string.IsNullOrEmpty(prefix) ? "" : ":" + prefix);
        }
    }

    /// <summary>
    /// A directory of one-secret-per-file entries, keyed like the
    /// environment: `api.token` reads `&lt;dir&gt;/API_TOKEN`.
    ///
    /// <para>This is the shape of a mounted Kubernetes Secret, a Docker or
    /// Swarm secret, and a systemd credentials directory, so those all work
    /// with no further configuration. One trailing newline is stripped -
    /// tools that write these files disagree about it, and a newline is
    /// never part of a secret on purpose.</para>
    /// </summary>
    public class FileProvider : IProvider
    {
        private readonly string dir;
        private readonly string prefix;

        public FileProvider(string dir, string prefix = null)
        {
            this.dir = dir ?? "";
            this.prefix = prefix;
        }

        public string Lookup(string name)
        {
            string file = Path.Combine(dir, Names.EnvKey(name, prefix));

            string text;
            try
            {
                text = File.ReadAllText(file);
            }
            catch (FileNotFoundException)
            {
                // An absent file - or an absent directory - means "no
                // secrets here", exactly like a missing .env. Anything else
                // (permission denied, an unreadable mount) is a store that
                // could not answer.
                return null;
            }
            catch (DirectoryNotFoundException)
            {
                return null;
            }
            catch (Exception err)
            {
                throw new SekretoError(
                    "sekreto: file provider cannot read " + file + ": " + err.Message);
            }

            if (text.EndsWith("\r\n", StringComparison.Ordinal))
            {
                return text.Substring(0, text.Length - 2);
            }
            if (text.EndsWith("\n", StringComparison.Ordinal))
            {
                return text.Substring(0, text.Length - 1);
            }

            return text;
        }

        public string Describe()
        {
            return "file:" + dir;
        }
    }

    public static class Addr
    {
        /// <summary>
        /// An address with any userinfo replaced by `[redacted]`, for
        /// messages.
        ///
        /// <para>Every refusal below names the address it refused, and one of
        /// them fires precisely because the address carries a credential - so
        /// printing it verbatim wrote the password to stderr and into the
        /// logs. It cannot be cleaned up afterwards either: that password was
        /// never resolved as a secret, so Redact has never seen it and never
        /// will. The host is what a reader needs to identify which chain entry
        /// is at fault; the userinfo is not.</para>
        /// </summary>
        public static string Safe(string addr)
        {
            int mark = addr.IndexOf("://", StringComparison.Ordinal);
            if (-1 == mark)
            {
                return addr;
            }

            string rest = addr.Substring(mark + 3);
            int stop = rest.IndexOfAny(new[] { '/', '?', '#' });
            string authority = -1 == stop ? rest : rest.Substring(0, stop);

            int at = authority.LastIndexOf('@');
            if (-1 == at)
            {
                return addr;
            }

            return addr.Substring(0, mark + 3) + "[redacted]" + addr.Substring(mark + 3 + at);
        }

        /// <summary>
        /// Refuse to send a secret-bearing credential in the clear.
        ///
        /// <para>A vault API is HTTPS in any real deployment; plaintext is a
        /// dev-mode convenience. Sending a token over http to anything but
        /// the local machine puts both the token and the secret it fetches
        /// on the wire for anyone on the path, so sekreto will not do it.
        /// Loopback stays allowed: that is `vault server -dev`,
        /// `boru vault serve`, and this repo's own test harness.</para>
        ///
        /// <para>The address is read by hand, in the same handful of steps in
        /// every port, rather than by each platform's URL parser. That is
        /// deliberate. Twelve parsers disagree about malformed input - where
        /// userinfo ends, whether `0177.0.0.1` is loopback, what an unclosed
        /// bracket means - and a check that answers differently in different
        /// ports is not a check.</para>
        ///
        /// <para>The rule this parse obeys, and the reason it can be trusted:
        /// it is never more permissive than the HTTP client that will dial
        /// the address. It ends the authority at `/`, `?` or `#` only, so a
        /// client that also breaks on `\` (WHATWG does) can only ever see a
        /// SHORTER host than this does. It refuses userinfo outright rather
        /// than locating its end. It compares the host literally, so a
        /// numeric form no parser here agrees on is refused rather than
        /// guessed at.</para>
        /// </summary>
        public static void Check(string addr)
        {
            string scheme;
            if (addr.StartsWith("https://", StringComparison.Ordinal))
            {
                scheme = "https://";
            }
            else if (addr.StartsWith("http://", StringComparison.Ordinal))
            {
                scheme = "http://";
            }
            else
            {
                throw new SekretoError("sekreto: not an http(s) address: " + Safe(addr));
            }

            string rest = addr.Substring(scheme.Length);
            int end = rest.IndexOfAny(new[] { '/', '?', '#' });
            string authority = -1 == end ? rest : rest.Substring(0, end);

            // Userinfo is refused outright rather than parsed around, and on
            // https as well as http. No store this library speaks
            // authenticates by userinfo - they take a token or a signature -
            // so an address carrying one is a mistake at best. At worst it is
            // the attack this whole method exists to stop:
            // http://localhost:8200@evil.example.com/ is a request to
            // evil.example.com that reads, to anything that splits the
            // authority on ':', as loopback.
            if (authority.Contains('@'))
            {
                throw new SekretoError(
                    "sekreto: refusing an address with embedded credentials: " + Safe(addr));
            }

            // An opening bracket with no closing one is not an address at all.
            if (authority.StartsWith("[", StringComparison.Ordinal)
                && !authority.Contains(']'))
            {
                throw new SekretoError("sekreto: not a valid http(s) address: " + Safe(addr));
            }

            if ("https://" == scheme)
            {
                return;
            }

            // A bracketed IPv6 literal keeps its brackets. Splitting the
            // authority on the first colon yields "[", so http://[::1]:8200
            // could never match - which made the "[::1]" entry below
            // unreachable, and refused a legitimate local vault.
            string host;
            if (authority.StartsWith("[", StringComparison.Ordinal))
            {
                host = authority.Substring(0, authority.IndexOf(']') + 1);
            }
            else
            {
                int colon = authority.IndexOf(':');
                host = -1 == colon ? authority : authority.Substring(0, colon);
            }
            host = host.ToLowerInvariant();

            if ("localhost" == host || "127.0.0.1" == host || "::1" == host || "[::1]" == host)
            {
                return;
            }

            throw new SekretoError(
                "sekreto: refusing to send a token in plaintext to " + Safe(addr) + " (use https)");
        }
    }

    /// <summary>
    /// The bridge between sekreto and voxgig/plugin: what a provider kind
    /// is as a plugin definition, which four kinds are built in, and the
    /// small value helpers every definition reads its spec through.
    /// </summary>
    public static class Providers
    {
        public static string Text(object value)
        {
            return null == value ? null : Convert.ToString(value);
        }

        public static string TextOr(object value, string fallback)
        {
            return null == value ? fallback : Convert.ToString(value);
        }

        /// <summary>
        /// The export key under which a provider definition publishes the
        /// provider it built. Sekreto reads `&lt;ref&gt;/provider` off the
        /// host.
        /// </summary>
        public const string ProviderExport = "provider";

        /// <summary>
        /// The voxgig/plugin error code a SekretoError travels under when
        /// it is raised inside a definition's `define`.
        ///
        /// <para>plugin wraps a code-less error raised by a callback as
        /// `plugin_define_failed`, and keeps an error that already carries
        /// a code. A provider that refuses its own configuration - `kv: 3`,
        /// a missing project - raises a SekretoError, and that message is
        /// pinned by the spec byte for byte, so it must come back out of
        /// the host exactly as it went in. ProviderPlugin gives it this
        /// code on the way in; Sekreto turns it back into a SekretoError on
        /// the way out.</para>
        /// </summary>
        public const string ErrorCode = "sekreto_error";

        /// <summary>
        /// A provider kind, as a voxgig/plugin definition.
        ///
        /// <para>This is the whole bridge between the two libraries. The
        /// definition's name is the `kind` a spec names; its `define` reads
        /// the spec as `inst.Options()`, builds the provider with `make`,
        /// and exports it. Nothing runs at `activate`: a provider opens
        /// nothing until its first lookup, so there is nothing to capture -
        /// a provider that does hold a resource acquires it there and lets
        /// the instance scope unwind it.</para>
        ///
        /// <para>Every built-in and every plugin is made this way, so a
        /// custom provider kind is one call:</para>
        ///
        /// <code>
        /// Providers.ProviderPlugin("mystore", spec =&gt; new MyProvider(Providers.Text(spec.GetValueOrDefault("addr"))))
        /// </code>
        /// </summary>
        public static Definition ProviderPlugin(
            string kind, Func<Dictionary<string, object>, IProvider> make)
        {
            var definition = new Definition(kind);

            definition.Define = inst =>
            {
                var spec = inst.Options() as Dictionary<string, object>
                    ?? new Dictionary<string, object>();

                IProvider provider;

                try
                {
                    provider = make(spec);
                }
                catch (SekretoError err)
                {
                    throw new PluginException(
                        ErrorCode, err.Message,
                        Types.Details("ref", inst.Ref, "cause", err.Message));
                }

                inst.Export(ProviderExport, provider);
            };

            return definition;
        }

        /// <summary>
        /// THE BUILT-IN PROVIDER KINDS - the same four in every port, in a
        /// fresh list.
        ///
        /// <para>What makes a kind built in is that it needs nothing of the
        /// platform beyond reading a local file: no socket, no TLS, no
        /// crypto, no child process. These four are the floor every chain
        /// stands on, and a chain that reads secrets from options, the
        /// environment, a plaintext `.env` and a mounted secret directory
        /// works with no plugin loaded at all.</para>
        /// </summary>
        public static List<Definition> Builtins()
        {
            return new List<Definition>
            {
                ProviderPlugin("env", spec =>
                    new EnvProvider(Text(spec.GetValueOrDefault("prefix")))),

                ProviderPlugin("memory", spec =>
                    new MemoryProvider(
                        spec.GetValueOrDefault("values") as Dictionary<string, object>,
                        Text(spec.GetValueOrDefault("prefix")))),

                ProviderPlugin("dotenv", spec =>
                    new DotenvProvider(
                        TextOr(spec.GetValueOrDefault("file"), ".env"),
                        Text(spec.GetValueOrDefault("prefix")))),

                ProviderPlugin("file", spec =>
                    new FileProvider(
                        TextOr(spec.GetValueOrDefault("dir"), ""),
                        Text(spec.GetValueOrDefault("prefix")))),
            };
        }

        /// <summary>
        /// The kinds this library ships as built-ins, in catalog order.
        /// </summary>
        public static readonly string[] BuiltinKinds =
        {
            "env", "memory", "dotenv", "file",
        };

        /// <summary>
        /// The kinds this library ships as PLUGINS, so that a kind nobody
        /// ships can be told from one the caller simply did not pass in.
        /// The names are here, in the core; the code is not.
        /// </summary>
        public static readonly string[] PluginKinds =
        {
            "hashicorp", "boru", "awssecrets", "awsparams", "gcpsecrets",
            "azuresecrets", "onepassword", "doppler", "infisical", "secretspec",
        };
    }
}
