// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Aws.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The `awssecrets` and `awsparams` provider kinds: AWS Secrets Manager and
// SSM Parameter Store.
//
// Two kinds in one file because they share their credential resolution and
// their signed round-trip. THE SIGNING TRAVELS WITH THEM: `sigv4` and the
// SHA-256 it is built from are in this module, not in the core, which is
// the sharpest instance of the core/plugin line - the core of no port
// imports a hash function.
//
// A port of typescript/plugins/aws.ts, which is canonical.

import Foundation

import Sekreto

// A SCOPED import: plugin exports a `Json` of its own, and the only name
// this file wants from it is `Definition`.
import struct VoxgigPlugin.Definition

/// The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now.
func awsnow() -> String {
  let stamp = DateFormatter()
  stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
  stamp.timeZone = TimeZone(identifier: "UTC")
  stamp.locale = Locale(identifier: "en_US_POSIX")
  return stamp.string(from: Date())
}

/// Region and credentials, resolved for one call.
struct Awsauth {
  let region: String
  let keyid: String
  let secret: String
  let session: String?
}

/// Region and credentials, from config first and the standard AWS_*
/// environment variables second - those are AWS's own convention, and a
/// pod or CI job that has them set should just work. Missing either is an
/// error: an AWS store with no credentials could not answer.
func awsauth(
  _ region: String?, _ keyid: String?, _ secret: String?, _ session: String?
) throws -> Awsauth {
  let useregion = first(region, getenv("AWS_REGION"), getenv("AWS_DEFAULT_REGION"))
  let usekeyid = first(keyid, getenv("AWS_ACCESS_KEY_ID"))
  let usesecret = first(secret, getenv("AWS_SECRET_ACCESS_KEY"))
  let usesession = first(session, getenv("AWS_SESSION_TOKEN"))

  if useregion.isEmpty {
    throw SekretoError("sekreto: aws: no region (set region or AWS_REGION)")
  }

  if usekeyid.isEmpty || usesecret.isEmpty {
    throw SekretoError(
      "sekreto: aws: no credentials"
        + " (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)")
  }

  return Awsauth(
    region: useregion,
    keyid: usekeyid,
    secret: usesecret,
    session: usesession.isEmpty ? nil : usesession
  )
}

/// One signed call to an AWS JSON-1.1 API.
func awscall(
  _ region: String?,
  _ keyid: String?,
  _ secret: String?,
  _ session: String?,
  _ addr: String?,
  _ service: String,
  _ target: String,
  _ payload: String
) throws -> Answer {
  let auth = try awsauth(region, keyid, secret, session)

  // The China partition lives under its own suffix; every other commercial
  // region is plain amazonaws.com.
  let suffix = auth.region.hasPrefix("cn-") ? ".amazonaws.com.cn" : ".amazonaws.com"
  let useaddr = first(addr, "https://\(service).\(auth.region)\(suffix)")
  try checkaddr(useaddr)

  let url = trimslash(useaddr) + "/"

  var extras = Ordered<String>()
  extras["content-type"] = "application/x-amz-json-1.1"
  extras["x-amz-target"] = target

  let signed = sigv4(
    Signing(
      method: "POST",
      url: url,
      service: service,
      region: auth.region,
      keyid: auth.keyid,
      secret: auth.secret,
      datetime: awsnow(),
      headers: extras,
      body: payload,
      session: auth.session
    ))

  var headers = extras
  for (key, value) in signed.pairs {
    headers[key] = value
  }

  return try fetchjson("POST", url, headers, payload)
}

/// Does this AWS error body name one of the not-found types? Those are a
/// miss; every other failure is a store that could not answer.
func awsmiss(_ body: Json?, _ types: [String]) -> Bool {
  guard let errtype = body.dig("__type").asstr else { return false }

  for want in types where errtype.contains(want) {
    return true
  }

  return false
}

/// AWS Secrets Manager.
///
/// `api.token` reads the secret named `api` (the vaultref path, so
/// `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
/// SecretString - the AWS idiom of one JSON map per secret. A SecretString
/// that is not JSON is the value itself, under the conventional field
/// `value`. Requests are SigV4-signed in-tree; see Sigv4.swift.
public final class AwssecretsProvider: Provider {

  private let region: String?
  private let keyid: String?
  private let secret: String?
  private let session: String?
  private let addr: String?

  public init(
    region: String? = nil,
    keyid: String? = nil,
    secret: String? = nil,
    session: String? = nil,
    addr: String? = nil
  ) {
    self.region = region
    self.keyid = keyid
    self.secret = secret
    self.session = session
    self.addr = addr
  }

  public func lookup(_ name: String) throws -> String? {
    let ref = try vaultref(name)

    let res = try awscall(
      region, keyid, secret, session, addr,
      "secretsmanager",
      "secretsmanager.GetSecretValue",
      Json.stringify(Json.obj([("SecretId", .str(ref.path))]))
    )

    if 400 == res.status && awsmiss(res.body, ["ResourceNotFoundException"]) { return nil }

    if 200 != res.status {
      throw SekretoError("sekreto: aws secretsmanager error: \(res.status)")
    }

    guard let text = res.body.dig("SecretString").asstr else {
      // A binary secret has no fields to address; only the conventional
      // `value` field can mean "the bytes themselves".
      guard let binary = res.body.dig("SecretBinary").asstr, "value" == ref.field else {
        return nil
      }

      guard let decoded = unbase64(binary) else {
        throw SekretoError("sekreto: aws secretsmanager: undecodable secret")
      }

      return decoded
    }

    if let parsed = Json.parse(text), let fields = parsed.asmap {
      return fields[ref.field].text
    }

    // A plain-string secret is the whole value; it has no named fields.
    return "value" == ref.field ? text : nil
  }

  // Config only, never the environment: describe() feeds the spec's
  // sources group, which must answer the same everywhere.
  public func describe() -> String {
    return "awssecrets:\(region ?? "")"
  }
}

/// AWS SSM Parameter Store.
///
/// `db.pass.main` reads the parameter `/db/pass/main` (under an optional
/// prefix path), decrypted. Parameter Store carries flat strings, so there
/// is no field indirection.
public final class AwsparamsProvider: Provider {

  private let region: String?
  private let keyid: String?
  private let secret: String?
  private let session: String?
  private let addr: String?
  private let prefix: String?

  public init(
    region: String? = nil,
    keyid: String? = nil,
    secret: String? = nil,
    session: String? = nil,
    addr: String? = nil,
    prefix: String? = nil
  ) {
    self.region = region
    self.keyid = keyid
    self.secret = secret
    self.session = session
    self.addr = addr
    self.prefix = prefix
  }

  public func lookup(_ name: String) throws -> String? {
    let payload = Json.obj([
      ("Name", .str(try awsparam(name, prefix))),
      ("WithDecryption", .bool(true)),
    ])

    let res = try awscall(
      region, keyid, secret, session, addr,
      "ssm",
      "AmazonSSM.GetParameter",
      Json.stringify(payload)
    )

    if 400 == res.status && awsmiss(res.body, ["ParameterNotFound"]) { return nil }

    if 200 != res.status {
      throw SekretoError("sekreto: aws ssm error: \(res.status)")
    }

    return res.body.dig("Parameter", "Value").text
  }

  public func describe() -> String {
    return "awsparams:\(region ?? "")\(prefix ?? "")"
  }
}

/// The kinds, as voxgig/plugin definitions.
public let awssecrets: Definition = providerplugin("awssecrets") { spec in
  AwssecretsProvider(
    region: spec.region, keyid: spec.keyid, secret: spec.secret,
    session: spec.session, addr: spec.addr)
}

public let awsparams: Definition = providerplugin("awsparams") { spec in
  AwsparamsProvider(
    region: spec.region, keyid: spec.keyid, secret: spec.secret,
    session: spec.session, addr: spec.addr, prefix: spec.prefix)
}
