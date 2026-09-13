// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Azuresecrets.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Azure Key Vault, as a voxgig/plugin definition.

package com.voxgig.sekreto.plugins

import com.voxgig.sekreto.*
import com.voxgig.sekreto.Providers.checkaddr

/** The Key Vault audience an Azure token is minted for. */
private val RESOURCE = "https://vault.azure.net"

/** Azure Key Vault.
  *
  * `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
  * names allow nothing else), current version. The token comes from
  * config, then a client-credentials login when tenant/clientid/
  * clientsecret are given, then the IMDS managed-identity endpoint - so on
  * Azure's own platform no credential configuration is needed.
  *
  * As with GCP, the IMDS call is plain http to a link-local host by
  * platform design and carries no credential; the login and vault
  * addresses are `checkaddr`-guarded.
  */
class Azuresecrets(
    vault: Option[String] = None,
    token: Option[String] = None,
    tenant: Option[String] = None,
    clientid: Option[String] = None,
    clientsecret: Option[String] = None,
    loginaddr: Option[String] = None,
    imdsaddr: Option[String] = None,
    apiversion: Option[String] = None,
) extends Provider:

  // A configured token is kept forever; logged-in and IMDS tokens carry
  // expires_in and are renewed shortly before they run out.
  private var livetoken: Option[String] = None
  private var renewat: Long = Long.MaxValue

  private def login(): String =
    if token.exists(_.nonEmpty) then token.get
    else if tenant.exists(_.nonEmpty) &&
      clientid.exists(_.nonEmpty) &&
      clientsecret.exists(_.nonEmpty)
    then
      val useloginaddr = first(loginaddr, Some("https://login.microsoftonline.com"))
      checkaddr(useloginaddr)

      val url = trimslash(useloginaddr) + "/" + tenant.get + "/oauth2/v2.0/token"
      val form = "grant_type=client_credentials&client_id=" + uriescape(clientid.get) +
        "&client_secret=" + uriescape(clientsecret.get) +
        "&scope=" + uriescape(s"$RESOURCE/.default")

      val res = fetchjson(
        "POST",
        url,
        Map("content-type" -> "application/x-www-form-urlencoded"),
        Some(form),
      )

      val got = res.body.dig("access_token").text
      if 200 != res.status || !got.exists(_.nonEmpty) then
        throw SekretoError(s"sekreto: azure login failed: ${res.status}")

      renewat = renewtime(res.body.dig("expires_in"))
      got.get
    else
      val imds = trimslash(first(imdsaddr, Some("http://169.254.169.254"))) +
        "/metadata/identity/oauth2/token?api-version=2018-02-01&resource=" +
        uriescape(RESOURCE)

      val res = fetchjson("GET", imds, Map("Metadata" -> "true"))

      val got = res.body.dig("access_token").text
      if 200 != res.status || !got.exists(_.nonEmpty) then
        throw SekretoError(
          "sekreto: azure: no token, no client credentials, and IMDS did not answer",
        )

      renewat = renewtime(res.body.dig("expires_in"))
      got.get

  override def lookup(name: String): Option[String] =
    val usevault = vault.getOrElse("")
    if usevault.isEmpty then throw SekretoError("sekreto: azure: no vault")

    // Only an explicit scheme is a URL; a vault NAMED httpvault must still
    // become https://httpvault.vault.azure.net.
    val vaulturl =
      if usevault.startsWith("http://") || usevault.startsWith("https://") then usevault
      else s"https://$usevault.vault.azure.net"
    checkaddr(vaulturl)

    if livetoken.isEmpty || System.currentTimeMillis >= renewat then livetoken = Some(login())

    val url = trimslash(vaulturl) + "/secrets/" + flatname(name, "-") +
      "?api-version=" + first(apiversion, Some("7.4"))

    val res = fetchjson("GET", url, Map("authorization" -> s"Bearer ${livetoken.getOrElse("")}"))

    if 404 == res.status then None
    else if 200 != res.status then
      throw SekretoError(s"sekreto: azure error: ${res.status}: ${bare(url)}")
    else res.body.dig("value").text

  override def describe(): String = s"azuresecrets:${vault.getOrElse("")}"

/** The `azuresecrets` provider kind, as a voxgig/plugin definition. A consumer
  * imports this and hands it to `Sekreto`; a consumer that does not gets a
  * `Sekreto` that cannot build a chain entry of that kind.
  */
val azuresecrets: Definition = providerplugin("azuresecrets", spec =>
  Azuresecrets(
    spec.vault,
    spec.token,
    spec.tenant,
    spec.clientid,
    spec.clientsecret,
    spec.loginaddr,
    spec.imdsaddr,
    spec.apiversion,
  ))
