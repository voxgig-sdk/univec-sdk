// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Infisical.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The `infisical` provider kind: Infisical.
//
// A plugin, not a built-in: it opens a socket, to the API and to the
// universal-auth login it can take a token from.
//
// A port of typescript/plugins/infisical.ts, which is canonical.

import Foundation

import Sekreto

// A SCOPED import: plugin exports a `Json` of its own, and the only name
// this file wants from it is `Definition`.
import struct VoxgigPlugin.Definition

/// Infisical.
///
/// `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
/// convention is environment-style keys) at a secret path in one
/// environment of a project. Auth is a token, or a universal-auth (machine
/// identity) login with clientid/clientsecret.
public final class InfisicalProvider: Provider {

  private let addr: String?
  private let token: String?
  private let clientid: String?
  private let clientsecret: String?
  private let project: String?
  private let environment: String?
  private let path: String?

  private var livetoken: String?
  private var renewat: Double = Double.greatestFiniteMagnitude

  public init(
    addr: String? = nil,
    token: String? = nil,
    clientid: String? = nil,
    clientsecret: String? = nil,
    project: String? = nil,
    environment: String? = nil,
    path: String? = nil
  ) {
    self.addr = addr
    self.token = token
    self.clientid = clientid
    self.clientsecret = clientsecret
    self.project = project
    self.environment = environment
    self.path = path
  }

  private func login(_ useaddr: String) throws -> String {
    if let use = token, !use.isEmpty { return use }

    let useclientid = clientid ?? ""
    let useclientsecret = clientsecret ?? ""

    if useclientid.isEmpty || useclientsecret.isEmpty {
      throw SekretoError("sekreto: infisical: no token and no client credentials")
    }

    let payload = Json.obj([
      ("clientId", .str(useclientid)),
      ("clientSecret", .str(useclientsecret)),
    ])

    var headers = Ordered<String>()
    headers["content-type"] = "application/json"

    let res = try fetchjson(
      "POST", "\(useaddr)/api/v1/auth/universal-auth/login", headers, Json.stringify(payload))

    let got = res.body.dig("accessToken").text

    if 200 != res.status || (got?.isEmpty ?? true) {
      throw SekretoError("sekreto: infisical login failed: \(res.status)")
    }

    // camelCase, unlike everyone else's expires_in.
    renewat = renewtime(res.body.dig("expiresIn"))

    return got!
  }

  public func lookup(_ name: String) throws -> String? {
    let useaddr = trimslash(first(addr, "https://app.infisical.com"))
    try checkaddr(useaddr)

    let useproject = project ?? ""
    let useenvironment = environment ?? ""

    if useproject.isEmpty || useenvironment.isEmpty {
      throw SekretoError("sekreto: infisical: no project/environment")
    }

    if nil == livetoken || nowms() >= renewat {
      livetoken = try login(useaddr)
    }

    let url =
      "\(useaddr)/api/v3/secrets/raw/" + (try envkey(name))
      + "?workspaceId=" + uriescape(useproject)
      + "&environment=" + uriescape(useenvironment)
      + "&secretPath=" + uriescape(first(path, "/"))

    var headers = Ordered<String>()
    headers["authorization"] = "Bearer \(livetoken ?? "")"

    let res = try fetchjson("GET", url, headers)

    if 404 == res.status { return nil }

    if 200 != res.status {
      throw SekretoError("sekreto: infisical error: \(res.status)")
    }

    return res.body.dig("secret", "secretValue").text
  }

  public func describe() -> String {
    return "infisical:\(project ?? "")/\(environment ?? "")"
  }
}

/// The kind, as a voxgig/plugin definition.
public let infisical: Definition = providerplugin("infisical") { spec in
  InfisicalProvider(
    addr: spec.addr,
    token: spec.token,
    clientid: spec.clientid,
    clientsecret: spec.clientsecret,
    project: spec.project,
    environment: spec.environment,
    path: spec.path
  )
}
