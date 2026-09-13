// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Onepassword.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// 1Password Connect, as a voxgig/plugin definition.

package com.voxgig.sekreto.plugins

import com.voxgig.sekreto.*
import com.voxgig.sekreto.Providers.checkaddr

/** 1Password, through a Connect server.
  *
  * The item titled `api.token` (titles keep their dots), in the named
  * vault. The value is the field with purpose PASSWORD, or the field
  * labelled `value`. A vault that cannot be found is an error - config
  * names it, so its absence is a broken store, not a missing secret.
  */
class Onepassword(
    addr: Option[String] = None,
    token: Option[String] = None,
    vault: Option[String] = None,
) extends Provider:

  private var vaultid: Option[String] = None

  private def auth(): Map[String, String] =
    Map("authorization" -> s"Bearer ${token.getOrElse("")}")

  private def resolvevault(useaddr: String): String =
    val want = vault.getOrElse("")
    if want.isEmpty then throw SekretoError("sekreto: onepassword: no vault")

    val res = fetchjson("GET", s"$useaddr/v1/vaults", auth())

    val list = res.body.asarr
    if 200 != res.status || list.isEmpty then
      throw SekretoError(s"sekreto: onepassword error: ${res.status}: listing vaults")

    val found = list.get.find: entry =>
      val id = entry.dig("id").text
      id.contains(want) || entry.dig("name").text.contains(want)

    found match
      case Some(entry) => entry.dig("id").text.getOrElse("")
      case None        => throw SekretoError(s"sekreto: onepassword: no vault named $want")

  override def lookup(name: String): Option[String] =
    checkname(name)

    val useaddr = trimslash(addr.getOrElse(""))
    if useaddr.isEmpty then throw SekretoError("sekreto: onepassword: no addr")
    checkaddr(useaddr)

    val id = vaultid.getOrElse:
      val resolved = resolvevault(useaddr)
      vaultid = Some(resolved)
      resolved

    val filter = uriescape(s"""title eq "$name"""")
    val found = fetchjson("GET", s"$useaddr/v1/vaults/$id/items?filter=$filter", auth())

    val items = found.body.asarr
    if 200 != found.status || items.isEmpty then
      throw SekretoError(s"sekreto: onepassword error: ${found.status}: finding $name")

    if items.get.isEmpty then None
    else
      val itemid = items.get.head.dig("id").text.getOrElse("")
      val item = fetchjson("GET", s"$useaddr/v1/vaults/$id/items/$itemid", auth())

      if 200 != item.status then
        throw SekretoError(s"sekreto: onepassword error: ${item.status}: reading $name")

      val fields = item.body.dig("fields").asarr.getOrElse(List.empty)

      fields.find(field => field.dig("purpose").asstr.contains("PASSWORD")) match
        case Some(field) => field.dig("value").text
        case None =>
          fields.find(field => field.dig("label").asstr.contains("value")) match
            case Some(field) => field.dig("value").text
            case None        => None

  override def describe(): String = s"onepassword:${vault.getOrElse("")}"

/** The `onepassword` provider kind, as a voxgig/plugin definition. A consumer
  * imports this and hands it to `Sekreto`; a consumer that does not gets a
  * `Sekreto` that cannot build a chain entry of that kind.
  */
val onepassword: Definition = providerplugin("onepassword", spec =>
  Onepassword(spec.addr, spec.token, spec.vault))
