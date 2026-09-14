// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Secretspec.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The `secretspec` provider kind: SecretSpec, through its CLI.
//
// A plugin, not a built-in: it spawns a child process.
//
// A port of typescript/plugins/secretspec.ts, which is canonical.

import Foundation

import Sekreto

// A SCOPED import: plugin exports a `Json` of its own, and the only name
// this file wants from it is `Definition`.
import struct VoxgigPlugin.Definition

/// SecretSpec (https://secretspec.dev).
///
/// SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
/// project needs - plus a chain of its own backends to satisfy them from.
/// That makes it the same shape as sekreto one level down, and the reason
/// to support it is the same reason sekreto exists: a project that has
/// already declared its secrets there should not have to declare them
/// again here.
///
/// `backend` selects one of SecretSpec's backends (`--provider`) and is
/// called `backend` here only because `provider` already means something
/// else in this library.
///
/// A reason is required, not optional: SecretSpec records every read in an
/// audit log and refuses to read at all without one.
public final class SecretspecProvider: Provider {

  private let command: String
  private let file: String?
  private let profile: String?
  private let backend: String?
  private let reason: String?
  private let prefix: String?

  public init(
    command: String? = nil,
    file: String? = nil,
    profile: String? = nil,
    backend: String? = nil,
    reason: String? = nil,
    prefix: String? = nil
  ) {
    self.command = first(command, "secretspec")
    self.file = file
    self.profile = profile
    self.backend = backend
    self.reason = reason
    self.prefix = prefix
  }

  public func lookup(_ name: String) throws -> String? {
    let key = try envkey(name, prefix)

    // `--file` comes BEFORE the subcommand; everything else after it.
    var argv = [command]
    if let use = file, !use.isEmpty { argv += ["--file", use] }
    argv += ["get", key]
    if let use = backend, !use.isEmpty { argv += ["--provider", use] }
    if let use = profile, !use.isEmpty { argv += ["--profile", use] }
    argv += ["--reason", first(reason, "sekreto")]

    let ran = try runcmd(argv, ProcessInfo.processInfo.environment, command)

    if 0 == ran.status {
      // The value and one newline, and nothing else.
      return dropsuffix(ran.out, "\n")
    }

    if secretspecmiss(ran.why, key) { return nil }

    throw SekretoError(
      "sekreto: secretspec error: " + (ran.why.isEmpty ? "exit \(ran.status)" : ran.why))
  }

  public func describe() -> String {
    let use = backend ?? ""
    return use.isEmpty ? "secretspec" : "secretspec:\(use)"
  }
}

/// Does this SecretSpec failure mean "no such secret" rather than "I could
/// not answer"?
///
/// MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
/// `Provider backend 'keyring' not found`, which is a store that could not
/// answer at all - and reading that as a miss is the worst failure this
/// library has, because the chain then falls through to a weaker store
/// without saying so. The key is required to appear, so the two cannot be
/// confused.
public func secretspecmiss(_ why: String, _ key: String) -> Bool {
  return why.contains("Secret '\(key)' not found")
}

/// The kind, as a voxgig/plugin definition.
public let secretspec: Definition = providerplugin("secretspec") { spec in
  SecretspecProvider(
    command: spec.command,
    file: spec.file,
    profile: spec.profile,
    backend: spec.backend,
    reason: spec.reason,
    prefix: spec.prefix
  )
}
