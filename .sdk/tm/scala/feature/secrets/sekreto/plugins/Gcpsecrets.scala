// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Gcpsecrets.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// GCP Secret Manager, as a voxgig/plugin definition.

package com.voxgig.sekreto.plugins

import java.nio.charset.StandardCharsets
import java.util.Base64

import com.voxgig.sekreto.*
import com.voxgig.sekreto.Providers.checkaddr

/** GCP Secret Manager.
  *
  * `api.token` reads secret `api_token` (dots flattened to `_`; Secret
  * Manager ids have no hierarchy and reject dots), latest version. The
  * token comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the
  * GCE/GKE metadata server - so on Google's own platform no credential
  * configuration is needed at all.
  *
  * The metadata call itself is plain http to a link-local host by platform
  * design; no credential rides on it, so `checkaddr` guards the Secret
  * Manager address instead.
  */
class Gcpsecrets(
    project: Option[String] = None,
    token: Option[String] = None,
    addr: Option[String] = None,
    metadataaddr: Option[String] = None,
) extends Provider:

  // A configured token is kept forever; a metadata-server token carries
  // expires_in and is renewed shortly before it runs out.
  private var livetoken: Option[String] = None
  private var renewat: Long = Long.MaxValue

  private def usemetadataaddr(): String =
    metadataaddr.filter(_.nonEmpty) match
      case Some(value) => value
      case None =>
        getenv("GCE_METADATA_HOST").filter(_.nonEmpty) match
          case Some(host) => s"http://$host"
          case None       => "http://metadata.google.internal"

  private def login(): String =
    val configured = first(token, getenv("GOOGLE_OAUTH_ACCESS_TOKEN"))
    if configured.nonEmpty then configured
    else
      val url = trimslash(usemetadataaddr()) +
        "/computeMetadata/v1/instance/service-accounts/default/token"

      val res = fetchjson("GET", url, Map("Metadata-Flavor" -> "Google"))

      val got = res.body.dig("access_token").text
      if 200 != res.status || !got.exists(_.nonEmpty) then
        throw SekretoError("sekreto: gcp: no token and metadata server did not answer")

      renewat = renewtime(res.body.dig("expires_in"))

      got.get

  override def lookup(name: String): Option[String] =
    val useproject = project.getOrElse("")
    if useproject.isEmpty then throw SekretoError("sekreto: gcp: no project")

    val useaddr = first(addr, Some("https://secretmanager.googleapis.com"))
    checkaddr(useaddr)

    if livetoken.isEmpty || System.currentTimeMillis >= renewat then livetoken = Some(login())

    val url = trimslash(useaddr) + "/v1/projects/" + useproject + "/secrets/" +
      flatname(name, "_") + "/versions/latest:access"

    val res = fetchjson("GET", url, Map("authorization" -> s"Bearer ${livetoken.getOrElse("")}"))

    if 404 == res.status then None
    else if 200 != res.status then
      throw SekretoError(s"sekreto: gcp error: ${res.status}: $url")
    else
      res.body.dig("payload", "data").asstr match
        case None => None
        // See the aws provider: an undecodable payload is a SekretoError.
        case Some(data) =>
          try Some(String(Base64.getDecoder.decode(data), StandardCharsets.UTF_8))
          catch
            case _: IllegalArgumentException =>
              throw SekretoError("sekreto: gcp: undecodable secret")

  override def describe(): String = s"gcpsecrets:${project.getOrElse("")}"

/** The `gcpsecrets` provider kind, as a voxgig/plugin definition. A consumer
  * imports this and hands it to `Sekreto`; a consumer that does not gets a
  * `Sekreto` that cannot build a chain entry of that kind.
  */
val gcpsecrets: Definition = providerplugin("gcpsecrets", spec =>
  Gcpsecrets(spec.project, spec.token, spec.addr, spec.metadataaddr))
