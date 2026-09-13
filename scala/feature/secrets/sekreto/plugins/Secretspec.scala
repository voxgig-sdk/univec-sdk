// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Secretspec.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// SecretSpec, as a voxgig/plugin definition.

package com.voxgig.sekreto.plugins

import scala.jdk.CollectionConverters.*

import com.voxgig.sekreto.*

/** SecretSpec (https://secretspec.dev).
  *
  * SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
  * project needs - plus a chain of its own backends to satisfy them from.
  * That makes it the same shape as sekreto one level down, and the reason
  * to support it is the same reason sekreto exists: a project that has
  * already declared its secrets there should not have to declare them
  * again here.
  *
  * Read through its CLI, as boru is, because that is the interface it
  * offers a program in another language: `secretspec get API_TOKEN` prints
  * the value on stdout and nothing else. A sekreto name maps to a
  * SecretSpec key exactly as it maps to an environment variable -
  * `api.token` is `API_TOKEN` - which is the convention SecretSpec's own
  * examples use.
  *
  * `backend` selects one of SecretSpec's backends (`--provider`, e.g.
  * `keyring` or `dotenv://.env`) and is called `backend` here only because
  * `provider` already means something else in this library.
  *
  * A reason is required, not optional: SecretSpec records every read in an
  * audit log and refuses to read at all without one. sekreto sends
  * `sekreto` unless told otherwise, so the audit trail says which tool
  * asked.
  */
class Secretspec(
    commandgiven: Option[String] = None,
    file: Option[String] = None,
    profile: Option[String] = None,
    backend: Option[String] = None,
    reason: Option[String] = None,
    prefix: Option[String] = None,
) extends Provider:

  private val command: String = commandgiven.filter(_.nonEmpty).getOrElse("secretspec")

  override def lookup(name: String): Option[String] =
    val key = envkey(name, prefix)

    val args = scala.collection.mutable.ListBuffer(command)
    file.filter(_.nonEmpty).foreach(value => args ++= List("--file", value))
    args ++= List("get", key)
    backend.filter(_.nonEmpty).foreach(value => args ++= List("--provider", value))
    profile.filter(_.nonEmpty).foreach(value => args ++= List("--profile", value))
    args ++= List("--reason", first(reason, Some("sekreto")))

    val ran = runcmd(ProcessBuilder(args.asJava), command)

    if 0 == ran.status then
      // The value and one newline, and nothing else.
      Some(dropsuffix(ran.out, "\n"))
    else if secretspecmiss(ran.why, key) then None
    else
      throw SekretoError(
        "sekreto: secretspec error: " +
          (if ran.why.isEmpty then s"exit ${ran.status}" else ran.why),
      )

  override def describe(): String =
    "secretspec" + (if backend.exists(_.nonEmpty) then s":${backend.get}" else "")

/** Does this SecretSpec failure mean "no such secret" rather than "I could
  * not answer"?
  *
  * SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
  * not declare and one declared with no value, and both are misses: this
  * store does not hold it, so the chain carries on.
  *
  * MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
  * `Provider backend 'keyring' not found`, which is a store that could not
  * answer at all - and reading that as a miss is the worst failure this
  * library has, because the chain then falls through to a weaker store
  * without saying so. The key is required to appear, so the two cannot be
  * confused.
  */
private[plugins] def secretspecmiss(why: String, key: String): Boolean =
  why.contains(s"Secret '$key' not found")

/** The `secretspec` provider kind, as a voxgig/plugin definition. A consumer
  * imports this and hands it to `Sekreto`; a consumer that does not gets a
  * `Sekreto` that cannot build a chain entry of that kind.
  */
val secretspec: Definition = providerplugin("secretspec", spec =>
  Secretspec(spec.command, spec.file, spec.profile, spec.backend, spec.reason, spec.prefix))
