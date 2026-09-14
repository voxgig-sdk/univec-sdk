// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Onepassword.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The `onepassword` provider kind: 1Password Connect.
//
// A plugin, not a built-in: it opens a socket.
//
// A port of typescript/plugins/onepassword.ts, which is canonical.

import Foundation

import Sekreto

// A SCOPED import: plugin exports a `Json` of its own, and the only name
// this file wants from it is `Definition`.
import struct VoxgigPlugin.Definition

/// 1Password, through a Connect server.
///
/// The item titled `api.token` (titles keep their dots), in the named
/// vault. The value is the field with purpose PASSWORD, or the field
/// labelled `value`. A vault that cannot be found is an error - config
/// names it, so its absence is a broken store, not a missing secret.
public final class OnepasswordProvider: Provider {

  private let addr: String?
  private let token: String?
  private let vault: String?

  private var vaultid: String?

  public init(addr: String? = nil, token: String? = nil, vault: String? = nil) {
    self.addr = addr
    self.token = token
    self.vault = vault
  }

  private func auth() -> Ordered<String> {
    var out = Ordered<String>()
    out["authorization"] = "Bearer \(token ?? "")"
    return out
  }

  private func resolvevault(_ useaddr: String) throws -> String {
    let want = vault ?? ""
    if want.isEmpty { throw SekretoError("sekreto: onepassword: no vault") }

    let res = try fetchjson("GET", "\(useaddr)/v1/vaults", auth())

    guard 200 == res.status, let list = res.body.aslist else {
      throw SekretoError("sekreto: onepassword error: \(res.status): listing vaults")
    }

    for entry in list {
      let id = entry.dig("id").text
      let name = entry.dig("name").text

      if want == id || want == name {
        return id ?? ""
      }
    }

    throw SekretoError("sekreto: onepassword: no vault named \(want)")
  }

  public func lookup(_ name: String) throws -> String? {
    _ = try checkname(name)

    let useaddr = trimslash(addr ?? "")
    if useaddr.isEmpty { throw SekretoError("sekreto: onepassword: no addr") }
    try checkaddr(useaddr)

    if nil == vaultid {
      vaultid = try resolvevault(useaddr)
    }

    let id = vaultid ?? ""

    let filter = uriescape("title eq \"\(name)\"")
    let found = try fetchjson("GET", "\(useaddr)/v1/vaults/\(id)/items?filter=\(filter)", auth())

    guard 200 == found.status, let items = found.body.aslist else {
      throw SekretoError("sekreto: onepassword error: \(found.status): finding \(name)")
    }

    if items.isEmpty { return nil }

    let itemid = items[0].dig("id").text ?? ""
    let item = try fetchjson("GET", "\(useaddr)/v1/vaults/\(id)/items/\(itemid)", auth())

    if 200 != item.status {
      throw SekretoError("sekreto: onepassword error: \(item.status): reading \(name)")
    }

    let fields = item.body.dig("fields").aslist ?? []

    // Two full passes, in order: a password field wins over a field merely
    // labelled `value`.
    for field in fields where "PASSWORD" == field.dig("purpose").asstr {
      return field.dig("value").text
    }

    for field in fields where "value" == field.dig("label").asstr {
      return field.dig("value").text
    }

    return nil
  }

  public func describe() -> String {
    return "onepassword:\(vault ?? "")"
  }
}

/// The kind, as a voxgig/plugin definition.
public let onepassword: Definition = providerplugin("onepassword") { spec in
  OnepasswordProvider(addr: spec.addr, token: spec.token, vault: spec.vault)
}
