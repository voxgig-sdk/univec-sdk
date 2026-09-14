// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/Aws.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Secrets Manager and SSM Parameter Store, as voxgig/plugin
// definitions - and the SigV4 signing they need.
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
    /// <summary>Region, credentials and endpoint shared by the AWS providers.</summary>
    internal sealed class AwsOptions
    {
        public string Region;
        public string Keyid;
        public string Secret;
        public string Session;
        public string Addr;
        public string Prefix;
    }

    internal static class Aws
    {
        /// <summary>The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now.</summary>
        internal static string Now()
        {
            return DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// Region and credentials, from config first and the standard AWS_*
        /// environment variables second - those are AWS's own convention,
        /// and a pod or CI job that has them set should just work. Missing
        /// either is an error: an AWS store with no credentials could not
        /// answer.
        /// </summary>
        internal static (string Region, string Keyid, string Secret, string Session) Auth(
            AwsOptions opts)
        {
            string region = opts.Region;
            if (string.IsNullOrEmpty(region))
            {
                region = Environment.GetEnvironmentVariable("AWS_REGION");
            }
            if (string.IsNullOrEmpty(region))
            {
                region = Environment.GetEnvironmentVariable("AWS_DEFAULT_REGION");
            }

            string keyid = string.IsNullOrEmpty(opts.Keyid)
                ? Environment.GetEnvironmentVariable("AWS_ACCESS_KEY_ID")
                : opts.Keyid;

            string secret = string.IsNullOrEmpty(opts.Secret)
                ? Environment.GetEnvironmentVariable("AWS_SECRET_ACCESS_KEY")
                : opts.Secret;

            string session = string.IsNullOrEmpty(opts.Session)
                ? Environment.GetEnvironmentVariable("AWS_SESSION_TOKEN")
                : opts.Session;

            if (string.IsNullOrEmpty(region))
            {
                throw new SekretoError("sekreto: aws: no region (set region or AWS_REGION)");
            }

            if (string.IsNullOrEmpty(keyid) || string.IsNullOrEmpty(secret))
            {
                throw new SekretoError(
                    "sekreto: aws: no credentials"
                    + " (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)");
            }

            return (region, keyid, secret, session);
        }

        /// <summary>One signed call to an AWS JSON-1.1 API.</summary>
        internal static (int Status, object Body) Call(
            AwsOptions opts, string service, string target, Dictionary<string, object> payload)
        {
            var (region, keyid, secret, session) = Auth(opts);

            // The China partition lives under its own suffix; every other
            // commercial region is plain amazonaws.com.
            string suffix = region.StartsWith("cn-", StringComparison.Ordinal)
                ? ".amazonaws.com.cn"
                : ".amazonaws.com";
            string addr = string.IsNullOrEmpty(opts.Addr)
                ? "https://" + service + "." + region + suffix
                : opts.Addr;
            Addr.Check(addr);

            string url = addr.TrimEnd('/') + "/";
            string body = Json.Stringify(payload);

            var headers = new Dictionary<string, string>
            {
                ["content-type"] = "application/x-amz-json-1.1",
                ["x-amz-target"] = target,
            };

            var sigheaders = new Dictionary<string, object>();
            foreach (var entry in headers)
            {
                sigheaders[entry.Key] = entry.Value;
            }

            var input = new Dictionary<string, object>
            {
                ["method"] = "POST",
                ["url"] = url,
                ["headers"] = sigheaders,
                ["body"] = body,
                ["service"] = service,
                ["region"] = region,
                ["keyid"] = keyid,
                ["secret"] = secret,
                ["datetime"] = Now(),
            };
            if (!string.IsNullOrEmpty(session))
            {
                input["session"] = session;
            }

            var all = new Dictionary<string, string>(headers);
            foreach (var entry in Sigv4.Sign(input))
            {
                all[entry.Key] = Convert.ToString(entry.Value);
            }

            return Http.FetchJson("POST", url, all, body);
        }

        /// <summary>
        /// Does this AWS error body name the not-found type? That is a miss;
        /// every other failure is a store that could not answer.
        /// </summary>
        internal static bool Miss(object body, string type)
        {
            object errtype = (body as Dictionary<string, object>)?.GetValueOrDefault("__type");
            return errtype is string text && text.Contains(type);
        }
    }

    /// <summary>
    /// AWS Secrets Manager.
    ///
    /// <para>`api.token` reads the secret named `api` (the vaultref path, so
    /// `db.pass.main` reads `db/pass`) and takes the `token` field of its
    /// JSON SecretString - the AWS idiom of one JSON map per secret. A
    /// SecretString that is not JSON is the value itself, under the
    /// conventional field `value`. Requests are SigV4-signed in-tree; see
    /// Sigv4.cs.</para>
    /// </summary>
    public class AwsSecretsProvider : IProvider
    {
        private readonly AwsOptions opts;

        public AwsSecretsProvider(string region = null, string keyid = null, string secret = null,
            string session = null, string addr = null)
        {
            opts = new AwsOptions
            {
                Region = region,
                Keyid = keyid,
                Secret = secret,
                Session = session,
                Addr = addr,
            };
        }

        public string Lookup(string name)
        {
            Dictionary<string, object> reference = Names.VaultRef(name);

            var (status, body) = Aws.Call(opts, "secretsmanager", "secretsmanager.GetSecretValue",
                new Dictionary<string, object> { ["SecretId"] = reference["path"] });

            if (400 == status && Aws.Miss(body, "ResourceNotFoundException"))
            {
                return null;
            }

            if (200 != status)
            {
                throw new SekretoError("sekreto: aws secretsmanager error: " + status);
            }

            string field = (string)reference["field"];
            object text = (body as Dictionary<string, object>)?.GetValueOrDefault("SecretString");

            if (!(text is string secretstring))
            {
                // A binary secret has no fields to address; only the
                // conventional `value` field can mean "the bytes themselves".
                object bin = (body as Dictionary<string, object>)?.GetValueOrDefault("SecretBinary");
                if (bin is string encoded && "value" == field)
                {
                    // FromBase64String throws FormatException on a bad
                    // payload, which is not a SekretoError and so escaped
                    // the library's own error type. A store that answered
                    // incoherently is an error.
                    try
                    {
                        return Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
                    }
                    catch (FormatException)
                    {
                        throw new SekretoError("sekreto: aws secretsmanager: undecodable secret");
                    }
                }
                return null;
            }

            object parsed = Json.Parse(secretstring);

            if (parsed is Dictionary<string, object> fields)
            {
                object value = fields.GetValueOrDefault(field);
                return null == value ? null : Convert.ToString(value);
            }

            // A plain-string secret is the whole value; it has no named
            // fields.
            return "value" == field ? secretstring : null;
        }

        // Config only, never the environment: Describe feeds the spec's
        // sources group, which must answer the same everywhere.
        public string Describe()
        {
            return "awssecrets:" + (opts.Region ?? "");
        }
    }

    /// <summary>
    /// AWS SSM Parameter Store.
    ///
    /// <para>`db.pass.main` reads the parameter `/db/pass/main` (under an
    /// optional prefix path), decrypted. Parameter Store carries flat
    /// strings, so there is no field indirection.</para>
    /// </summary>
    public class AwsParamsProvider : IProvider
    {
        private readonly AwsOptions opts;

        public AwsParamsProvider(string region = null, string keyid = null, string secret = null,
            string session = null, string addr = null, string prefix = null)
        {
            opts = new AwsOptions
            {
                Region = region,
                Keyid = keyid,
                Secret = secret,
                Session = session,
                Addr = addr,
                Prefix = prefix,
            };
        }

        public string Lookup(string name)
        {
            var (status, body) = Aws.Call(opts, "ssm", "AmazonSSM.GetParameter",
                new Dictionary<string, object>
                {
                    ["Name"] = Names.AwsParam(name, opts.Prefix),
                    ["WithDecryption"] = true,
                });

            if (400 == status && Aws.Miss(body, "ParameterNotFound"))
            {
                return null;
            }

            if (200 != status)
            {
                throw new SekretoError("sekreto: aws ssm error: " + status);
            }

            object value = ((body as Dictionary<string, object>)?.GetValueOrDefault("Parameter")
                as Dictionary<string, object>)?.GetValueOrDefault("Value");

            return null == value ? null : Convert.ToString(value);
        }

        public string Describe()
        {
            return "awsparams:" + (opts.Region ?? "") + (opts.Prefix ?? "");
        }
    }

    /// <summary>The <c>awssecrets</c> and <c>awsparams</c> provider kinds.</summary>
    public static class AwsPlugins
    {
        public static readonly Definition Secrets = Providers.ProviderPlugin(
            "awssecrets", spec => new AwsSecretsProvider(
                Providers.Text(spec.GetValueOrDefault("region")),
                Providers.Text(spec.GetValueOrDefault("keyid")),
                Providers.Text(spec.GetValueOrDefault("secret")),
                Providers.Text(spec.GetValueOrDefault("session")),
                Providers.Text(spec.GetValueOrDefault("addr"))));

        public static readonly Definition Params = Providers.ProviderPlugin(
            "awsparams", spec => new AwsParamsProvider(
                Providers.Text(spec.GetValueOrDefault("region")),
                Providers.Text(spec.GetValueOrDefault("keyid")),
                Providers.Text(spec.GetValueOrDefault("secret")),
                Providers.Text(spec.GetValueOrDefault("session")),
                Providers.Text(spec.GetValueOrDefault("addr")),
                Providers.Text(spec.GetValueOrDefault("prefix"))));
    }
}
