// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Doppler.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Doppler, as a voxgig/plugin definition.

package com.voxgig.sekreto.plugins

import scala.collection.immutable.ListMap

import com.voxgig.sekreto.*
import com.voxgig.sekreto.Providers.checkaddr

/** Doppler.
  *
  * The whole config is downloaded once - Doppler's own bulk endpoint - and
  * answered from memory, like a remote .env: `api.token` is the
  * `API_TOKEN` entry. A service token is config-scoped, so project and
  * config are only needed with broader tokens.
  */
class Doppler(
    token: Option[String] = None,
    project: Option[String] = None,
    config: Option[String] = None,
    addr: Option[String] = None,
) extends Provider:

  private var values: Option[Map[String, String]] = None

  private def load(): Map[String, String] =
    values match
      case Some(loaded) => loaded
      case None =>
        val useaddr = trimslash(first(addr, Some("https://api.doppler.com")))
        checkaddr(useaddr)

        var url = s"$useaddr/v3/configs/config/secrets/download?format=json"
        project.filter(_.nonEmpty).foreach(value => url += "&project=" + uriescape(value))
        config.filter(_.nonEmpty).foreach(value => url += "&config=" + uriescape(value))

        val res = fetchjson(
          "GET",
          url,
          Map("authorization" -> s"Bearer ${token.getOrElse("")}"),
        )

        val body = res.body.asobj
        if 200 != res.status || body.isEmpty then
          throw SekretoError(s"sekreto: doppler error: ${res.status}")

        var loaded = ListMap.empty[String, String]
        for (key, value) <- body.get do value.text.foreach(text => loaded = loaded.updated(key, text))

        values = Some(loaded)
        loaded

  override def lookup(name: String): Option[String] = load().get(envkey(name))

  override def describe(): String =
    "doppler" + (
      if project.exists(_.nonEmpty) then s":${project.get}/${config.getOrElse("")}" else ""
    )

/** The `doppler` provider kind, as a voxgig/plugin definition. A consumer
  * imports this and hands it to `Sekreto`; a consumer that does not gets a
  * `Sekreto` that cannot build a chain entry of that kind.
  */
val doppler: Definition = providerplugin("doppler", spec =>
  Doppler(spec.token, spec.project, spec.config, spec.addr))
