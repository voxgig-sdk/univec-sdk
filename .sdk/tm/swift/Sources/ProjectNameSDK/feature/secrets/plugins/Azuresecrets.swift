// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Azuresecrets.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The `azuresecrets` provider kind: Azure Key Vault.
//
// A plugin, not a built-in: it opens a socket, to the vault and to
// whichever login endpoint its credentials point at.
//
// A port of typescript/plugins/azuresecrets.ts, which is canonical.

import Foundation

import Sekreto

// A SCOPED import: plugin exports a `Json` of its own, and the only name
// this file wants from it is `Definition`.
import struct VoxgigPlugin.Definition

/// The Key Vault audience an Azure token is minted for.
let AZURERESOURCE = "https://vault.azure.net"

/// Azure Key Vault.
///
/// `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
/// names allow nothing else), current version. The token comes from
/// config, then a client-credentials login when tenant/clientid/
/// clientsecret are given, then the IMDS managed-identity endpoint - so on
/// Azure's own platform no credential configuration is needed.
///
/// As with GCP, the IMDS call is plain http to a link-local host by
/// platform design and carries no credential; the login and vault
/// addresses are `checkaddr`-guarded.
public final class AzuresecretsProvider: Provider {

  private let vault: String?
  private let token: String?
  private let tenant: String?
  private let clientid: String?
  private let clientsecret: String?
  private let loginaddr: String?
  private let imdsaddr: String?
  private let apiversion: String?

  private var livetoken: String?
  private var renewat: Double = Double.greatestFiniteMagnitude

  public init(
    vault: String? = nil,
    token: String? = nil,
    tenant: String? = nil,
    clientid: String? = nil,
    clientsecret: String? = nil,
    loginaddr: String? = nil,
    imdsaddr: String? = nil,
    apiversion: String? = nil
  ) {
    self.vault = vault
    self.token = token
    self.tenant = tenant
    self.clientid = clientid
    self.clientsecret = clientsecret
    self.loginaddr = loginaddr
    self.imdsaddr = imdsaddr
    self.apiversion = apiversion
  }

  private func login() throws -> String {
    if let use = token, !use.isEmpty { return use }

    let usetenant = tenant ?? ""
    let useclientid = clientid ?? ""
    let useclientsecret = clientsecret ?? ""

    if !usetenant.isEmpty && !useclientid.isEmpty && !useclientsecret.isEmpty {
      let useloginaddr = first(loginaddr, "https://login.microsoftonline.com")
      try checkaddr(useloginaddr)

      let url = trimslash(useloginaddr) + "/" + usetenant + "/oauth2/v2.0/token"
      let form =
        "grant_type=client_credentials&client_id=" + uriescape(useclientid)
        + "&client_secret=" + uriescape(useclientsecret)
        + "&scope=" + uriescape("\(AZURERESOURCE)/.default")

      var headers = Ordered<String>()
      headers["content-type"] = "application/x-www-form-urlencoded"

      let res = try fetchjson("POST", url, headers, form)

      let got = res.body.dig("access_token").text

      if 200 != res.status || (got?.isEmpty ?? true) {
        throw SekretoError("sekreto: azure login failed: \(res.status)")
      }

      renewat = renewtime(res.body.dig("expires_in"))

      return got!
    }

    let imds =
      trimslash(first(imdsaddr, "http://169.254.169.254"))
      + "/metadata/identity/oauth2/token?api-version=2018-02-01&resource="
      + uriescape(AZURERESOURCE)

    var headers = Ordered<String>()
    headers["Metadata"] = "true"

    let res = try fetchjson("GET", imds, headers)

    let got = res.body.dig("access_token").text

    if 200 != res.status || (got?.isEmpty ?? true) {
      throw SekretoError(
        "sekreto: azure: no token, no client credentials, and IMDS did not answer")
    }

    // IMDS sends expires_in as a STRING, unlike everybody else.
    renewat = renewtime(res.body.dig("expires_in"))

    return got!
  }

  public func lookup(_ name: String) throws -> String? {
    let usevault = vault ?? ""
    if usevault.isEmpty { throw SekretoError("sekreto: azure: no vault") }

    // Only an explicit scheme is a URL; a vault NAMED httpvault must still
    // become https://httpvault.vault.azure.net.
    let vaulturl =
      (usevault.hasPrefix("http://") || usevault.hasPrefix("https://"))
      ? usevault : "https://\(usevault).vault.azure.net"
    try checkaddr(vaulturl)

    if nil == livetoken || nowms() >= renewat {
      livetoken = try login()
    }

    let url =
      trimslash(vaulturl) + "/secrets/" + (try flatname(name, "-"))
      + "?api-version=" + first(apiversion, "7.4")

    var headers = Ordered<String>()
    headers["authorization"] = "Bearer \(livetoken ?? "")"

    let res = try fetchjson("GET", url, headers)

    if 404 == res.status { return nil }

    if 200 != res.status {
      throw SekretoError("sekreto: azure error: \(res.status): \(bare(url))")
    }

    return res.body.dig("value").text
  }

  public func describe() -> String {
    return "azuresecrets:\(vault ?? "")"
  }
}

/// The kind, as a voxgig/plugin definition.
public let azuresecrets: Definition = providerplugin("azuresecrets") { spec in
  AzuresecretsProvider(
    vault: spec.vault,
    token: spec.token,
    tenant: spec.tenant,
    clientid: spec.clientid,
    clientsecret: spec.clientsecret,
    loginaddr: spec.loginaddr,
    imdsaddr: spec.imdsaddr,
    apiversion: spec.apiversion
  )
}
