// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Doppler.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The `doppler` provider kind: Doppler.
//
// A plugin, not a built-in: it opens a socket.
//
// A port of typescript/plugins/doppler.ts, which is canonical.

import Foundation

import Sekreto

// A SCOPED import: plugin exports a `Json` of its own, and the only name
// this file wants from it is `Definition`.
import struct VoxgigPlugin.Definition

/// Doppler.
///
/// The whole config is downloaded once - Doppler's own bulk endpoint - and
/// answered from memory, like a remote .env: `api.token` is the
/// `API_TOKEN` entry. A service token is config-scoped, so project and
/// config are only needed with broader tokens.
public final class DopplerProvider: Provider {

  private let token: String?
  private let project: String?
  private let config: String?
  private let addr: String?

  private var values: Ordered<String>?

  public init(
    token: String? = nil, project: String? = nil, config: String? = nil, addr: String? = nil
  ) {
    self.token = token
    self.project = project
    self.config = config
    self.addr = addr
  }

  private func load() throws -> Ordered<String> {
    if let loaded = values { return loaded }

    let useaddr = trimslash(first(addr, "https://api.doppler.com"))
    try checkaddr(useaddr)

    var url = "\(useaddr)/v3/configs/config/secrets/download?format=json"
    if let use = project, !use.isEmpty { url += "&project=" + uriescape(use) }
    if let use = config, !use.isEmpty { url += "&config=" + uriescape(use) }

    var headers = Ordered<String>()
    headers["authorization"] = "Bearer \(token ?? "")"

    let res = try fetchjson("GET", url, headers)

    guard 200 == res.status, let body = res.body.asmap else {
      throw SekretoError("sekreto: doppler error: \(res.status)")
    }

    var loaded = Ordered<String>()

    for (key, value) in body.pairs {
      if let text = value.text { loaded[key] = text }
    }

    // Only a successful load is remembered: a failed one retries.
    values = loaded
    return loaded
  }

  public func lookup(_ name: String) throws -> String? {
    return try load()[try envkey(name)]
  }

  public func describe() -> String {
    let useproject = project ?? ""
    return useproject.isEmpty ? "doppler" : "doppler:\(useproject)/\(config ?? "")"
  }
}

/// The kind, as a voxgig/plugin definition.
public let doppler: Definition = providerplugin("doppler") { spec in
  DopplerProvider(
    token: spec.token, project: spec.project, config: spec.config, addr: spec.addr)
}
