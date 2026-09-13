// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/src/Support.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// How a provider kind becomes a voxgig/plugin definition.
//
// This file is the whole bridge between the two libraries. A provider kind
// is a plugin `Definition` named after the kind; its `define` reads the
// instance's options as a `ProviderSpec`, builds the provider, and exports
// it under the key `provider`. `Sekreto` reads it back off the host. One
// helper makes every one of them, built-in or plugin, shipped or custom:
//
//     val mystore = providerplugin("mystore", spec => Mystore(spec.addr))
//
// A port of typescript/src/provider/support.ts, which is canonical.

package com.voxgig.sekreto

import scala.collection.immutable.ListMap

import voxgig.plugin.Inst
import voxgig.plugin.PluginError
import voxgig.plugin.VMap
import voxgig.plugin.VNum
import voxgig.plugin.VOpaque
import voxgig.plugin.VStr
import voxgig.plugin.Value

/** A voxgig/plugin definition, under the name a `plugins` list reads by.
  *
  * plugin's scala port makes a definition a CASE CLASS with typed callback
  * fields rather than a map of `Any`, because scala's value model is a
  * sealed hierarchy that cannot hold a function. So this is an alias and
  * not a shape of sekreto's own: `List[Definition]` is what a consumer
  * passes, and it is plugin's type throughout.
  */
type Definition = voxgig.plugin.Definition

/** The export key under which a provider definition publishes the provider
  * it built. `Sekreto` reads `<ref>/provider` off the host.
  */
val PROVIDER_EXPORT: String = "provider"

/** The voxgig/plugin error code a SekretoError travels under when it is
  * raised inside a definition's `define`.
  *
  * plugin wraps a code-less error raised by a callback as
  * `plugin_define_failed`, and keeps one that already carries a code. A
  * provider that refuses its own configuration - `kv: 3`, a missing project
  * - raises a SekretoError, and the spec pins that message byte for byte,
  * so it must come back out of the host exactly as it went in.
  * `providerplugin` gives it this code on the way in; `Sekreto` takes it
  * off on the way out. Nowhere else catches and rewraps.
  */
val ERROR_CODE: String = "sekreto_error"

/** A provider kind, as a voxgig/plugin definition.
  *
  * Nothing runs at `activate`: a provider opens nothing until its first
  * lookup, so there is nothing to capture - a provider that does hold a
  * resource acquires it there and lets the instance scope unwind it.
  */
def providerplugin(kind: String, make: ProviderSpec => Provider): Definition =
  val define: Inst => Unit = inst =>
    val provider =
      try make(specof(inst.options))
      catch
        case err: SekretoError =>
          val text = Option(err.getMessage).getOrElse("")
          throw PluginError(ERROR_CODE, text, Map("ref" -> VStr(inst.ref), "cause" -> VStr(text)))

    // A provider is a live object, not data, so it crosses as plugin's own
    // escape hatch for exactly that - the model carries numbers and strings
    // and this is neither.
    inst.`export`(PROVIDER_EXPORT, VOpaque(provider))

  voxgig.plugin.Definition(name = kind, define = Some(define))

// --- the spec across the plugin boundary -----------------------------
//
// plugin's options are its own value model - a sealed hierarchy of null,
// boolean, number, string, list and map - and sekreto's spec is a typed
// case class, so the two are written out field by field rather than
// reflected over. `optionsof` is what `Sekreto.declare` hands to
// `host.load`; `specof` is what a definition's `define` reads back. They
// are inverses, and `PluginsTest`'s "a provider spec survives the plugin
// boundary" is what says so - a field added to one and forgotten in the
// other would otherwise be lost in silence, and only for the kinds no
// conformance case exercises.

/** The pairs that were set, as a plugin map.
  *
  * An absent field is ABSENT from the options rather than a present null.
  * `specof` reads it back as None either way, but plugin's model keeps the
  * two apart on purpose, and a spec that never mentioned a key should not
  * gain one crossing the boundary.
  */
private def fields(pairs: List[(String, Option[Value])]): Value =
  VMap(ListMap.from(pairs.collect { case (key, Some(value)) => (key, value) }))

private def str(value: Option[String]): Option[Value] = value.map(VStr.apply)

private def optstr(options: Value, key: String): Option[String] =
  options.get(key).flatMap(_.asString)

/** A ProviderSpec as plugin instance options. */
def optionsof(spec: ProviderSpec): Value =
  val auth: Option[Value] = spec.auth.map: useauth =>
    fields(
      List(
        "method" -> Some(VStr(useauth.method)),
        "mount" -> str(useauth.mount),
        "role" -> str(useauth.role),
        "jwt" -> str(useauth.jwt),
        "jwtfile" -> str(useauth.jwtfile),
        "roleid" -> str(useauth.roleid),
        "secretid" -> str(useauth.secretid),
      ),
    )

  val values: Option[Value] = spec.values.map: source =>
    VMap(ListMap.from(source.map((key, value) => (key, VStr(value)))))

  fields(
    List(
      "kind" -> Some(VStr(spec.kind)),
      "name" -> str(spec.name),
      "prefix" -> str(spec.prefix),
      "file" -> str(spec.file),
      "values" -> values,
      "dir" -> str(spec.dir),
      "addr" -> str(spec.addr),
      "token" -> str(spec.token),
      "mount" -> str(spec.mount),
      // Every number in plugin's model is a Double, JSON's one number type.
      "kv" -> spec.kv.map(value => VNum(value.toDouble)),
      "vaultnamespace" -> str(spec.vaultnamespace),
      "auth" -> auth,
      "command" -> str(spec.command),
      "profile" -> str(spec.profile),
      "backend" -> str(spec.backend),
      "reason" -> str(spec.reason),
      "namespace" -> str(spec.namespace),
      "home" -> str(spec.home),
      "region" -> str(spec.region),
      "keyid" -> str(spec.keyid),
      "secret" -> str(spec.secret),
      "session" -> str(spec.session),
      "project" -> str(spec.project),
      "vault" -> str(spec.vault),
      "tenant" -> str(spec.tenant),
      "clientid" -> str(spec.clientid),
      "clientsecret" -> str(spec.clientsecret),
      "loginaddr" -> str(spec.loginaddr),
      "imdsaddr" -> str(spec.imdsaddr),
      "metadataaddr" -> str(spec.metadataaddr),
      "apiversion" -> str(spec.apiversion),
      "config" -> str(spec.config),
      "environment" -> str(spec.environment),
      "path" -> str(spec.path),
    ),
  )

/** Plugin instance options as a ProviderSpec. */
def specof(options: Value): ProviderSpec =
  val values = options.get("values").collect:
    case entry: VMap =>
      ListMap.from(entry.keys.map(key => (key, entry.at(key).asString.getOrElse(""))))

  val auth = options.get("auth").collect:
    case entry: VMap =>
      AuthSpec(
        method = entry.at("method").asString.getOrElse(""),
        mount = optstr(entry, "mount"),
        role = optstr(entry, "role"),
        jwt = optstr(entry, "jwt"),
        jwtfile = optstr(entry, "jwtfile"),
        roleid = optstr(entry, "roleid"),
        secretid = optstr(entry, "secretid"),
      )

  ProviderSpec(
    kind = optstr(options, "kind").getOrElse(""),
    name = optstr(options, "name"),
    prefix = optstr(options, "prefix"),
    file = optstr(options, "file"),
    values = values,
    dir = optstr(options, "dir"),
    addr = optstr(options, "addr"),
    token = optstr(options, "token"),
    mount = optstr(options, "mount"),
    kv = options.get("kv").flatMap(_.asDouble).map(_.toInt),
    vaultnamespace = optstr(options, "vaultnamespace"),
    auth = auth,
    command = optstr(options, "command"),
    profile = optstr(options, "profile"),
    backend = optstr(options, "backend"),
    reason = optstr(options, "reason"),
    namespace = optstr(options, "namespace"),
    home = optstr(options, "home"),
    region = optstr(options, "region"),
    keyid = optstr(options, "keyid"),
    secret = optstr(options, "secret"),
    session = optstr(options, "session"),
    project = optstr(options, "project"),
    vault = optstr(options, "vault"),
    tenant = optstr(options, "tenant"),
    clientid = optstr(options, "clientid"),
    clientsecret = optstr(options, "clientsecret"),
    loginaddr = optstr(options, "loginaddr"),
    imdsaddr = optstr(options, "imdsaddr"),
    metadataaddr = optstr(options, "metadataaddr"),
    apiversion = optstr(options, "apiversion"),
    config = optstr(options, "config"),
    environment = optstr(options, "environment"),
    path = optstr(options, "path"),
  )
