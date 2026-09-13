// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Boru.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// A boru vault, as a voxgig/plugin definition.

package com.voxgig.sekreto.plugins

import com.voxgig.sekreto.*
import com.voxgig.sekreto.Providers.checkaddr

/** A boru vault (https://github.com/boru-lang/boru).
  *
  * Two ways in, both boru's own.
  *
  * With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
  * secret on stdout and nothing else. The passphrase is read by boru
  * itself from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as config
  * and never puts it on a command line, where it would show up in the
  * process table.
  *
  * With an `addr`, boru's wire protocol: `boru vault serve` publishes a
  * read-only, HashiCorp-shaped provision API (boru's
  * design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
  * from `boru vault grant`. A sekreto name is already a valid boru alias,
  * and boru aliases keep their dots, so `api.token` is the single path
  * segment `api.token` - not the `api`/`token` split a HashiCorp KV gets.
  * The value is the `value` field. A 404 is a miss; anything else the
  * server refuses (a revoked capability, a sealed vault) is an error.
  *
  * boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
  * credential *broker*, built precisely so the caller never receives the
  * credential. `vault serve` is the provision endpoint, built to hand the
  * value back - that is the one sekreto uses.
  */
class Boru(
    commandgiven: Option[String] = None,
    namespace: Option[String] = None,
    home: Option[String] = None,
    addrgiven: Option[String] = None,
    tokengiven: Option[String] = None,
    mountgiven: Option[String] = None,
) extends Provider:

  private val command: String = commandgiven.filter(_.nonEmpty).getOrElse("boru")
  private val addr: String = addrgiven.map(trimslash).getOrElse("")
  private val token: String = tokengiven.getOrElse("")
  private val mount: String = mountgiven.filter(_.nonEmpty).getOrElse("secret")

  override def lookup(name: String): Option[String] =
    checkname(name)

    if addr.nonEmpty then wirelookup(name)
    else
      val alias = namespace.filter(_.nonEmpty).map(space => s"$space:$name").getOrElse(name)

      val builder = ProcessBuilder(command, "vault", "get", "--reveal", alias)

      home.filter(_.nonEmpty).foreach(value => builder.environment().put("BORU_HOME", value))

      val ran = runcmd(builder, command)

      if 0 == ran.status then
        // boru prints the value and one newline, and nothing else.
        Some(dropsuffix(ran.out, "\n"))
      // "no alias named" is boru saying it does not hold this secret,
      // which is a miss: the chain carries on to the next provider. A
      // locked vault or a wrong passphrase is not a miss - treating it as
      // one would fall through to a weaker store without saying so.
      else if borumiss(ran.why) then None
      else
        throw SekretoError(
          "sekreto: boru vault error: " +
            (if ran.why.isEmpty then s"exit ${ran.status}" else ran.why),
        )

  private def wirelookup(name: String): Option[String] =
    checkaddr(addr)

    // The dotted name stays one path segment: boru aliases keep dots.
    val alias = namespace.filter(_.nonEmpty).map(space => s"$space/$name").getOrElse(name)
    val url = s"$addr/v1/$mount/data/$alias"

    val res = fetchjson("GET", url, Map("X-Vault-Token" -> token))

    if 404 == res.status then None
    else if 200 != res.status then
      throw SekretoError(s"sekreto: boru serve error: ${res.status}: $url")
    else res.body.dig("data", "data", "value").text

  override def describe(): String =
    if addr.nonEmpty then s"boru:$addr"
    else "boru" + (if namespace.exists(_.nonEmpty) then s":${namespace.get}" else "")

/** Does this boru failure mean "no such secret" rather than "I could not
  * answer"? Matched on boru's own wording for a missing alias.
  */
private[plugins] def borumiss(why: String): Boolean = why.contains("no alias named")

/** The `boru` provider kind, as a voxgig/plugin definition. A consumer
  * imports this and hands it to `Sekreto`; a consumer that does not gets a
  * `Sekreto` that cannot build a chain entry of that kind.
  */
val boru: Definition = providerplugin("boru", spec =>
  Boru(spec.command, spec.namespace, spec.home, spec.addr, spec.token, spec.mount))
