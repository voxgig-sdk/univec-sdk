// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Hashicorp.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// HashiCorp Vault, as a voxgig/plugin definition.

package com.voxgig.sekreto.plugins

import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Paths
import scala.collection.immutable.ListMap

import com.voxgig.sekreto.*
import com.voxgig.sekreto.Providers.checkaddr

/** HashiCorp Vault.
  *
  * KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
  * takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
  * `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
  * here" - a miss - so a vault can sit in a chain with fallbacks.
  *
  * A Vault Enterprise namespace rides the X-Vault-Namespace header, on
  * logins as well as reads.
  *
  * Instead of being handed a token, the provider can log in: Kubernetes
  * auth (the pod's service-account JWT, from its conventional path) or
  * AppRole. A failed login is an error, never a miss - it means this store
  * could not answer at all.
  */
class Hashicorp(
    addr: String,
    token: Option[String] = None,
    mountgiven: Option[String] = None,
    kvgiven: Option[Int] = None,
    vaultnamespace: Option[String] = None,
    auth: Option[AuthSpec] = None,
) extends Provider:

  private val mount: String = mountgiven.filter(_.nonEmpty).getOrElse("secret")
  private val kv: Int = kvgiven.getOrElse(2)

  // The working token: a configured token is kept forever, a logged-in
  // token is renewed shortly before its lease runs out - a long-running
  // process must not keep presenting a token the vault already expired.
  private var livetoken: Option[String] = token.filter(_.nonEmpty)
  private var renewat: Long = Long.MaxValue

  // A version typo like kv: 3 must not quietly behave as v2 and turn its
  // 404s into misses; there is nothing safe to assume it meant.
  if 1 != kv && 2 != kv then
    throw SekretoError(s"sekreto: hashicorp: unsupported kv version: $kv")

  private def baseheaders(): ListMap[String, String] =
    vaultnamespace.filter(_.nonEmpty) match
      case Some(value) => ListMap("X-Vault-Namespace" -> value)
      case None        => ListMap.empty

  private def login(): String =
    val use = auth.getOrElse(
      throw SekretoError("sekreto: hashicorp: no token and no auth method"),
    )

    val authmount = first(use.mount, Some(use.method))
    val url = trimslash(addr) + "/v1/auth/" + authmount + "/login"

    val body = use.method match
      case "kubernetes" =>
        val jwt = use.jwt.getOrElse:
          val file = use.jwtfile.getOrElse("/var/run/secrets/kubernetes.io/serviceaccount/token")
          try String(Files.readAllBytes(Paths.get(file)), StandardCharsets.UTF_8).trim
          catch
            case _: IOException =>
              throw SekretoError(s"sekreto: hashicorp: cannot read jwt file $file")

        Json.obj("role" -> Json.str(use.role.getOrElse("")), "jwt" -> Json.str(jwt))

      case "approle" =>
        Json.obj(
          "role_id" -> Json.str(use.roleid.getOrElse("")),
          "secret_id" -> Json.str(use.secretid.getOrElse("")),
        )

      case other => throw SekretoError(s"sekreto: hashicorp: unknown auth method: $other")

    val res = fetchjson("POST", url, baseheaders(), Some(Json.stringify(body)))

    val got = res.body.dig("auth", "client_token").text
    if 200 != res.status || !got.exists(_.nonEmpty) then
      throw SekretoError(s"sekreto: hashicorp login failed: ${res.status}: $url")

    renewat = renewtime(res.body.dig("auth", "lease_duration"))

    got.get

  override def lookup(name: String): Option[String] =
    checkaddr(addr)

    if livetoken.isEmpty || System.currentTimeMillis >= renewat then livetoken = Some(login())

    val ref = vaultref(name)
    val base = trimslash(addr) + "/v1/" + mount
    val url = if 1 == kv then s"$base/${ref.path}" else s"$base/data/${ref.path}"

    val headers = baseheaders().updated("X-Vault-Token", livetoken.getOrElse(""))

    val res = fetchjson("GET", url, headers)

    if 404 == res.status then None
    else if 200 != res.status then
      throw SekretoError(s"sekreto: hashicorp error: ${res.status}: $url")
    else
      val data = if 1 == kv then res.body.dig("data") else res.body.dig("data", "data")
      data.dig(ref.field).text

  override def describe(): String = s"hashicorp:$addr/$mount"

/** The `hashicorp` provider kind, as a voxgig/plugin definition. A consumer
  * imports this and hands it to `Sekreto`; a consumer that does not gets a
  * `Sekreto` that cannot build a chain entry of that kind.
  */
val hashicorp: Definition = providerplugin("hashicorp", spec =>
  Hashicorp(
    spec.addr.getOrElse(""),
    spec.token,
    spec.mount,
    spec.kv,
    spec.vaultnamespace,
    spec.auth,
  ))
