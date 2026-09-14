// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Hashicorp.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The `hashicorp` provider kind: HashiCorp Vault over its HTTP API.
//
// A plugin, not a built-in: it opens a socket. Import it and hand it to
// the Sekreto that needs it -
//
//     try makesekreto(chain, plugins: [hashicorp])
//
// A port of typescript/plugins/hashicorp.ts, which is canonical.

import Foundation

import Sekreto

// A SCOPED import: plugin exports a `Json` of its own, and the only name
// this file wants from it is `Definition`.
import struct VoxgigPlugin.Definition

/// HashiCorp Vault.
///
/// KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
/// takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
/// `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
/// here" - a miss - so a vault can sit in a chain with fallbacks.
///
/// A Vault Enterprise namespace rides the X-Vault-Namespace header, on
/// logins as well as reads.
///
/// Instead of being handed a token, the provider can log in: Kubernetes
/// auth (the pod's service-account JWT, from its conventional path) or
/// AppRole. A failed login is an error, never a miss - it means this store
/// could not answer at all.
public final class HashicorpProvider: Provider {

  private let addr: String
  private let mount: String
  private let kv: Int
  private let vaultnamespace: String?
  private let auth: AuthSpec?

  // The working token: a configured token is kept forever, a logged-in
  // token is renewed shortly before its lease runs out - a long-running
  // process must not keep presenting a token the vault already expired.
  private var livetoken: String?
  private var renewat: Double = Double.greatestFiniteMagnitude

  public init(
    addr: String,
    token: String? = nil,
    mount: String? = nil,
    kv: Int? = nil,
    vaultnamespace: String? = nil,
    auth: AuthSpec? = nil
  ) throws {
    self.addr = addr
    self.mount = first(mount, "secret")
    self.kv = kv ?? 2
    self.vaultnamespace = vaultnamespace
    self.auth = auth
    self.livetoken = (token?.isEmpty ?? true) ? nil : token

    // A version typo like kv: 3 must not quietly behave as v2 and turn its
    // 404s into misses; there is nothing safe to assume it meant.
    if 1 != self.kv && 2 != self.kv {
      throw SekretoError("sekreto: hashicorp: unsupported kv version: \(self.kv)")
    }
  }

  private func baseheaders() -> Ordered<String> {
    var out = Ordered<String>()

    if let space = vaultnamespace, !space.isEmpty {
      out["X-Vault-Namespace"] = space
    }

    return out
  }

  private func login() throws -> String {
    guard let use = auth else {
      throw SekretoError("sekreto: hashicorp: no token and no auth method")
    }

    let authmount = first(use.mount, use.method)
    let url = trimslash(addr) + "/v1/auth/" + authmount + "/login"

    var payload: Json

    switch use.method {
    case "kubernetes":
      var jwt = use.jwt ?? ""

      if jwt.isEmpty {
        let file = first(use.jwtfile, "/var/run/secrets/kubernetes.io/serviceaccount/token")

        guard case .text(let body) = readfile(file) else {
          throw SekretoError("sekreto: hashicorp: cannot read jwt file \(file)")
        }

        jwt = body.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      payload = Json.obj([("role", .str(use.role ?? "")), ("jwt", .str(jwt))])

    case "approle":
      payload = Json.obj([
        ("role_id", .str(use.roleid ?? "")),
        ("secret_id", .str(use.secretid ?? "")),
      ])

    default:
      throw SekretoError("sekreto: hashicorp: unknown auth method: \(use.method)")
    }

    let res = try fetchjson("POST", url, baseheaders(), Json.stringify(payload))

    let got = res.body.dig("auth", "client_token").text

    if 200 != res.status || (got?.isEmpty ?? true) {
      throw SekretoError("sekreto: hashicorp login failed: \(res.status): \(url)")
    }

    renewat = renewtime(res.body.dig("auth", "lease_duration"))

    return got!
  }

  public func lookup(_ name: String) throws -> String? {
    try checkaddr(addr)

    if nil == livetoken || nowms() >= renewat {
      livetoken = try login()
    }

    let ref = try vaultref(name)
    let base = trimslash(addr) + "/v1/" + mount
    let url = 1 == kv ? "\(base)/\(ref.path)" : "\(base)/data/\(ref.path)"

    var headers = baseheaders()
    headers["X-Vault-Token"] = livetoken ?? ""

    let res = try fetchjson("GET", url, headers)

    // A 404 is this vault saying it does not hold the secret, so the chain
    // carries on. Anything else it refuses is a store that could not
    // answer.
    if 404 == res.status { return nil }

    if 200 != res.status {
      throw SekretoError("sekreto: hashicorp error: \(res.status): \(url)")
    }

    let data = 1 == kv ? res.body.dig("data") : res.body.dig("data", "data")

    return data.dig(ref.field).text
  }

  public func describe() -> String {
    return "hashicorp:\(addr)/\(mount)"
  }
}

/// The kind, as a voxgig/plugin definition.
public let hashicorp: Definition = providerplugin("hashicorp") { spec in
  try HashicorpProvider(
    addr: spec.addr ?? "",
    token: spec.token,
    mount: spec.mount,
    kv: spec.kv,
    vaultnamespace: spec.vaultnamespace,
    auth: spec.auth
  )
}
