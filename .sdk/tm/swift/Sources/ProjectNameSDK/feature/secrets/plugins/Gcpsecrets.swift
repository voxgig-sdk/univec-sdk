// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Gcpsecrets.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The `gcpsecrets` provider kind: GCP Secret Manager.
//
// A plugin, not a built-in: it opens a socket, to the API and to the
// metadata server it can take a token from.
//
// A port of typescript/plugins/gcpsecrets.ts, which is canonical.

import Foundation

import Sekreto

// A SCOPED import: plugin exports a `Json` of its own, and the only name
// this file wants from it is `Definition`.
import struct VoxgigPlugin.Definition

/// GCP Secret Manager.
///
/// `api.token` reads secret `api_token` (dots flattened to `_`; Secret
/// Manager ids have no hierarchy and reject dots), latest version. The
/// token comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the
/// GCE/GKE metadata server - so on Google's own platform no credential
/// configuration is needed at all.
///
/// The metadata call itself is plain http to a link-local host by platform
/// design; no credential rides on it, so `checkaddr` guards the Secret
/// Manager address instead.
public final class GcpsecretsProvider: Provider {

  private let project: String?
  private let token: String?
  private let addr: String?
  private let metadataaddr: String?

  private var livetoken: String?
  private var renewat: Double = Double.greatestFiniteMagnitude

  public init(
    project: String? = nil,
    token: String? = nil,
    addr: String? = nil,
    metadataaddr: String? = nil
  ) {
    self.project = project
    self.token = token
    self.addr = addr
    self.metadataaddr = metadataaddr
  }

  private func usemetadataaddr() -> String {
    if let use = metadataaddr, !use.isEmpty { return use }

    if let host = getenv("GCE_METADATA_HOST"), !host.isEmpty { return "http://\(host)" }

    return "http://metadata.google.internal"
  }

  private func login() throws -> String {
    let configured = first(token, getenv("GOOGLE_OAUTH_ACCESS_TOKEN"))
    if !configured.isEmpty { return configured }

    let url =
      trimslash(usemetadataaddr())
      + "/computeMetadata/v1/instance/service-accounts/default/token"

    var headers = Ordered<String>()
    headers["Metadata-Flavor"] = "Google"

    let res = try fetchjson("GET", url, headers)

    let got = res.body.dig("access_token").text

    if 200 != res.status || (got?.isEmpty ?? true) {
      throw SekretoError("sekreto: gcp: no token and metadata server did not answer")
    }

    renewat = renewtime(res.body.dig("expires_in"))

    return got!
  }

  public func lookup(_ name: String) throws -> String? {
    let useproject = project ?? ""
    if useproject.isEmpty { throw SekretoError("sekreto: gcp: no project") }

    let useaddr = first(addr, "https://secretmanager.googleapis.com")
    try checkaddr(useaddr)

    if nil == livetoken || nowms() >= renewat {
      livetoken = try login()
    }

    let url =
      trimslash(useaddr) + "/v1/projects/" + useproject + "/secrets/"
      + (try flatname(name, "_")) + "/versions/latest:access"

    var headers = Ordered<String>()
    headers["authorization"] = "Bearer \(livetoken ?? "")"

    let res = try fetchjson("GET", url, headers)

    if 404 == res.status { return nil }

    if 200 != res.status {
      throw SekretoError("sekreto: gcp error: \(res.status): \(url)")
    }

    guard let data = res.body.dig("payload", "data").asstr else { return nil }

    guard let decoded = unbase64(data) else {
      throw SekretoError("sekreto: gcp: undecodable secret")
    }

    return decoded
  }

  public func describe() -> String {
    return "gcpsecrets:\(project ?? "")"
  }
}

/// The kind, as a voxgig/plugin definition.
public let gcpsecrets: Definition = providerplugin("gcpsecrets") { spec in
  GcpsecretsProvider(
    project: spec.project, token: spec.token, addr: spec.addr,
    metadataaddr: spec.metadataaddr)
}
