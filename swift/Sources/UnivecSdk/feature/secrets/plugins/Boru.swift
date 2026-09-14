// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Boru.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The `boru` provider kind: a boru vault, through its CLI or its wire
// protocol.
//
// A plugin, not a built-in: it spawns a child process, and over the wire
// it opens a socket.
//
// A port of typescript/plugins/boru.ts, which is canonical.

import Foundation

import Sekreto

// A SCOPED import: plugin exports a `Json` of its own, and the only name
// this file wants from it is `Definition`.
import struct VoxgigPlugin.Definition

/// A boru vault (https://github.com/boru-lang/boru).
///
/// Two ways in, both boru's own.
///
/// With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
/// secret on stdout and nothing else. The passphrase is read by boru
/// itself from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as config
/// and never puts it on a command line, where it would show up in the
/// process table.
///
/// With an `addr`, boru's wire protocol: `boru vault serve` publishes a
/// read-only, HashiCorp-shaped provision API, authenticated by a
/// capability token from `boru vault grant`. A sekreto name is already a
/// valid boru alias, and boru aliases keep their dots, so `api.token` is
/// the single path segment `api.token` - not the `api`/`token` split a
/// HashiCorp KV gets. The value is the `value` field.
public final class BoruProvider: Provider {

  private let command: String
  private let namespace: String?
  private let home: String?
  private let addr: String
  private let token: String
  private let mount: String

  public init(
    command: String? = nil,
    namespace: String? = nil,
    home: String? = nil,
    addr: String? = nil,
    token: String? = nil,
    mount: String? = nil
  ) {
    self.command = first(command, "boru")
    self.namespace = namespace
    self.home = home
    self.addr = trimslash(addr ?? "")
    self.token = token ?? ""
    self.mount = first(mount, "secret")
  }

  public func lookup(_ name: String) throws -> String? {
    _ = try checkname(name)

    if !addr.isEmpty { return try wirelookup(name) }

    // The CLI alias is namespace-qualified with a COLON; the wire one with
    // a slash. Both are boru's own spellings.
    var alias = name
    if let space = namespace, !space.isEmpty { alias = "\(space):\(name)" }

    var environment = ProcessInfo.processInfo.environment
    if let usehome = home, !usehome.isEmpty { environment["BORU_HOME"] = usehome }

    let ran = try runcmd(
      [command, "vault", "get", "--reveal", alias], environment, command)

    if 0 == ran.status {
      // boru prints the value and one newline, and nothing else.
      return dropsuffix(ran.out, "\n")
    }

    // "no alias named" is boru saying it does not hold this secret, which
    // is a miss: the chain carries on to the next provider. A locked vault
    // or a wrong passphrase is not a miss - treating it as one would fall
    // through to a weaker store without saying so.
    if borumiss(ran.why) { return nil }

    throw SekretoError(
      "sekreto: boru vault error: " + (ran.why.isEmpty ? "exit \(ran.status)" : ran.why))
  }

  private func wirelookup(_ name: String) throws -> String? {
    try checkaddr(addr)

    // The dotted name stays one path segment: boru aliases keep dots.
    var alias = name
    if let space = namespace, !space.isEmpty { alias = "\(space)/\(name)" }

    let url = "\(addr)/v1/\(mount)/data/\(alias)"

    var headers = Ordered<String>()
    headers["X-Vault-Token"] = token

    let res = try fetchjson("GET", url, headers)

    if 404 == res.status { return nil }

    if 200 != res.status {
      throw SekretoError("sekreto: boru serve error: \(res.status): \(url)")
    }

    return res.body.dig("data", "data", "value").text
  }

  public func describe() -> String {
    if !addr.isEmpty { return "boru:\(addr)" }

    let space = namespace ?? ""
    return space.isEmpty ? "boru" : "boru:\(space)"
  }
}

/// Does this boru failure mean "no such secret" rather than "I could not
/// answer"? Matched on boru's own wording for a missing alias.
public func borumiss(_ why: String) -> Bool {
  return why.contains("no alias named")
}

/// The kind, as a voxgig/plugin definition.
public let boru: Definition = providerplugin("boru") { spec in
  BoruProvider(
    command: spec.command,
    namespace: spec.namespace,
    home: spec.home,
    addr: spec.addr,
    token: spec.token,
    mount: spec.mount
  )
}
