// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Infisical.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Infisical, as a voxgig/plugin definition.

package com.voxgig.sekreto.plugins

import com.voxgig.sekreto.*
import com.voxgig.sekreto.Providers.checkaddr

/** Infisical.
  *
  * `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
  * convention is environment-style keys) at a secret path in one
  * environment of a project. Auth is a token, or a universal-auth (machine
  * identity) login with clientid/clientsecret.
  */
class Infisical(
    addr: Option[String] = None,
    token: Option[String] = None,
    clientid: Option[String] = None,
    clientsecret: Option[String] = None,
    project: Option[String] = None,
    environment: Option[String] = None,
    path: Option[String] = None,
) extends Provider:

  // A configured token is kept forever; a universal-auth token carries
  // expiresIn and is renewed shortly before it runs out.
  private var livetoken: Option[String] = None
  private var renewat: Long = Long.MaxValue

  private def login(useaddr: String): String =
    if token.exists(_.nonEmpty) then token.get
    else
      if !clientid.exists(_.nonEmpty) || !clientsecret.exists(_.nonEmpty) then
        throw SekretoError("sekreto: infisical: no token and no client credentials")

      val body = Json.obj(
        "clientId" -> Json.str(clientid.get),
        "clientSecret" -> Json.str(clientsecret.get),
      )

      val res = fetchjson(
        "POST",
        s"$useaddr/api/v1/auth/universal-auth/login",
        Map("content-type" -> "application/json"),
        Some(Json.stringify(body)),
      )

      val got = res.body.dig("accessToken").text
      if 200 != res.status || !got.exists(_.nonEmpty) then
        throw SekretoError(s"sekreto: infisical login failed: ${res.status}")

      renewat = renewtime(res.body.dig("expiresIn"))

      got.get

  override def lookup(name: String): Option[String] =
    val useaddr = trimslash(first(addr, Some("https://app.infisical.com")))
    checkaddr(useaddr)

    val useproject = project.getOrElse("")
    val useenvironment = environment.getOrElse("")
    if useproject.isEmpty || useenvironment.isEmpty then
      throw SekretoError("sekreto: infisical: no project/environment")

    if livetoken.isEmpty || System.currentTimeMillis >= renewat then
      livetoken = Some(login(useaddr))

    val url = s"$useaddr/api/v3/secrets/raw/" + envkey(name) +
      "?workspaceId=" + uriescape(useproject) +
      "&environment=" + uriescape(useenvironment) +
      "&secretPath=" + uriescape(first(path, Some("/")))

    val res = fetchjson("GET", url, Map("authorization" -> s"Bearer ${livetoken.getOrElse("")}"))

    if 404 == res.status then None
    else if 200 != res.status then throw SekretoError(s"sekreto: infisical error: ${res.status}")
    else res.body.dig("secret", "secretValue").text

  override def describe(): String =
    s"infisical:${project.getOrElse("")}/${environment.getOrElse("")}"

/** The `infisical` provider kind, as a voxgig/plugin definition. A consumer
  * imports this and hands it to `Sekreto`; a consumer that does not gets a
  * `Sekreto` that cannot build a chain entry of that kind.
  */
val infisical: Definition = providerplugin("infisical", spec =>
  Infisical(
    spec.addr,
    spec.token,
    spec.clientid,
    spec.clientsecret,
    spec.project,
    spec.environment,
    spec.path,
  ))
