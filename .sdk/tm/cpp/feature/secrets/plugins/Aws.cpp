// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Aws.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Aws.hpp"

#include <ctime>

#include "Httpjson.hpp"
#include "../sekreto/Providers.hpp"
#include "../sekreto/Sekreto.hpp"
#include "Sigv4.hpp"

namespace sekreto {

namespace {

// -------------------------------------------------------------------- aws

/// The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now. The only place
/// in this port that samples the clock for a signature - `sigv4` itself is
/// pure.
std::string awsnow() {
  std::time_t stamp = std::time(nullptr);
  std::tm parts;
  gmtime_r(&stamp, &parts);

  char buf[32];
  std::strftime(buf, sizeof(buf), "%Y%m%dT%H%M%SZ", &parts);

  return buf;
}

/// Region and credentials, resolved for one call.
struct Awsauth {
  std::string region;
  std::string keyid;
  std::string secret;
  std::string session;
};

/// From config first and the standard AWS_* environment variables second -
/// those are AWS's own convention, and a pod or CI job that has them set
/// should just work. Missing either is an error: an AWS store with no
/// credentials could not answer.
Awsauth awsauth(const std::string& region, const std::string& keyid,
                const std::string& secret, const std::string& session) {
  Awsauth out;

  out.region = first(region, envvar("AWS_REGION"), envvar("AWS_DEFAULT_REGION"));
  out.keyid = first(keyid, envvar("AWS_ACCESS_KEY_ID"));
  out.secret = first(secret, envvar("AWS_SECRET_ACCESS_KEY"));
  out.session = first(session, envvar("AWS_SESSION_TOKEN"));

  if (out.region.empty()) {
    throw SekretoError("sekreto: aws: no region (set region or AWS_REGION)");
  }

  if (out.keyid.empty() || out.secret.empty()) {
    throw SekretoError(
        "sekreto: aws: no credentials"
        " (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)");
  }

  return out;
}

/// One signed call to an AWS JSON-1.1 API.
Answer awscall(const std::string& region, const std::string& keyid,
               const std::string& secret, const std::string& session,
               const std::string& addr, const std::string& service,
               const std::string& target, const std::string& payload) {
  Awsauth auth = awsauth(region, keyid, secret, session);

  // The China partition lives under its own suffix; every other commercial
  // region is plain amazonaws.com.
  bool china = 0 == auth.region.compare(0, 3, "cn-");
  std::string suffix = china ? ".amazonaws.com.cn" : ".amazonaws.com";
  std::string useaddr = first(addr, "https://" + service + "." + auth.region + suffix);

  checkaddr(useaddr);

  std::string url = trimslash(useaddr) + "/";

  Ordered extras;
  extras.set("content-type", "application/x-amz-json-1.1");
  extras.set("x-amz-target", target);

  Signing input;
  input.method = "POST";
  input.url = url;
  input.service = service;
  input.region = auth.region;
  input.keyid = auth.keyid;
  input.secret = auth.secret;
  input.datetime = awsnow();
  input.headers = extras;
  input.body = payload;
  input.session = auth.session;

  Ordered headers = extras;
  for (const auto& entry : sigv4(input).pairs) {
    headers.set(entry.first, entry.second);
  }

  return fetchjson("POST", url, headers, payload);
}

/// Does this AWS error body name one of the not-found types? Those are a
/// miss; every other failure is a store that could not answer. AWS sends
/// `com.amazonaws...#ResourceNotFoundException`, so this is a CONTAINS.
bool awsmiss(const Json& body, const std::string& want) {
  std::string errtype;
  if (!body.get("__type").asstr(errtype)) return false;

  return std::string::npos != errtype.find(want);
}

/// AWS Secrets Manager.
///
/// `api.token` reads the secret named `api` (the vaultref path, so
/// `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
/// SecretString - the AWS idiom of one JSON map per secret. A SecretString
/// that is not JSON is the value itself, under the conventional field
/// `value`. Requests are SigV4-signed in-tree.
class AwssecretsProvider : public Provider {
 public:
  AwssecretsProvider(const std::string& region, const std::string& keyid,
                     const std::string& secret, const std::string& session,
                     const std::string& addr)
      : region_(region), keyid_(keyid), secret_(secret), session_(session), addr_(addr) {}

  std::optional<std::string> lookup(const std::string& name) override {
    VaultRef ref = vaultref(name);

    Answer res = awscall(region_, keyid_, secret_, session_, addr_, "secretsmanager",
                         "secretsmanager.GetSecretValue",
                         Json::stringify(Json::obj({{"SecretId", Json::str(ref.path)}})));

    if (400 == res.status && awsmiss(res.body, "ResourceNotFoundException")) {
      return std::nullopt;
    }

    if (200 != res.status) {
      throw SekretoError("sekreto: aws secretsmanager error: " + std::to_string(res.status));
    }

    std::string text;

    if (!res.body.get("SecretString").asstr(text)) {
      // A binary secret has no fields to address; only the conventional
      // `value` field can mean "the bytes themselves".
      std::string binary;
      if (!res.body.get("SecretBinary").asstr(binary) || "value" != ref.field) {
        return std::nullopt;
      }

      std::string decoded;
      if (!unbase64(binary, decoded)) {
        throw SekretoError("sekreto: aws secretsmanager: undecodable secret");
      }

      return decoded;
    }

    Json parsed;
    if (Json::parse(text, parsed) && parsed.isobj()) {
      return textof(parsed.get(ref.field));
    }

    // A plain-string secret is the whole value; it has no named fields.
    if ("value" == ref.field) return text;

    return std::nullopt;
  }

  // Config only, never the environment: describe() feeds the spec's
  // sources group, which must answer the same everywhere.
  std::string describe() const override { return "awssecrets:" + region_; }

 private:
  std::string region_;
  std::string keyid_;
  std::string secret_;
  std::string session_;
  std::string addr_;
};

/// AWS SSM Parameter Store.
///
/// `db.pass.main` reads the parameter `/db/pass/main` (under an optional
/// prefix path), decrypted. Parameter Store carries flat strings, so there
/// is no field indirection.
class AwsparamsProvider : public Provider {
 public:
  AwsparamsProvider(const std::string& region, const std::string& keyid,
                    const std::string& secret, const std::string& session,
                    const std::string& addr, const std::string& prefix)
      : region_(region),
        keyid_(keyid),
        secret_(secret),
        session_(session),
        addr_(addr),
        prefix_(prefix) {}

  std::optional<std::string> lookup(const std::string& name) override {
    Json payload = Json::obj({{"Name", Json::str(awsparam(name, prefix_))},
                              {"WithDecryption", Json::boolean(true)}});

    Answer res = awscall(region_, keyid_, secret_, session_, addr_, "ssm",
                         "AmazonSSM.GetParameter", Json::stringify(payload));

    if (400 == res.status && awsmiss(res.body, "ParameterNotFound")) return std::nullopt;

    if (200 != res.status) {
      throw SekretoError("sekreto: aws ssm error: " + std::to_string(res.status));
    }

    return textof(res.body.get("Parameter").get("Value"));
  }

  std::string describe() const override { return "awsparams:" + region_ + prefix_; }

 private:
  std::string region_;
  std::string keyid_;
  std::string secret_;
  std::string session_;
  std::string addr_;
  std::string prefix_;
};

}  // namespace

Definition awssecrets() {
  return providerplugin("awssecrets", [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
    return std::make_shared<AwssecretsProvider>(spec.region, spec.keyid, spec.secret,
                                                spec.session, spec.addr);
  });
}

Definition awsparams() {
  return providerplugin("awsparams", [](const ProviderSpec& spec) -> std::shared_ptr<Provider> {
    return std::make_shared<AwsparamsProvider>(spec.region, spec.keyid, spec.secret,
                                               spec.session, spec.addr, spec.prefix);
  });
}

}  // namespace sekreto
