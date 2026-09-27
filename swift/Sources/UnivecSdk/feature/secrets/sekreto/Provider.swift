// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (swift/src/Provider.swift)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// A source of secrets.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or nil to mean "ask the next one". Nothing else about a
// provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file, HashiCorp Vault or a boru vault.
//
// Two failure shapes, and they are never interchangeable. A store that
// does not hold the secret answers nil, and the chain carries on. A store
// that could not answer throws.

import Foundation

public protocol Provider: AnyObject {

  /// The value, or nil if this provider does not have it.
  func lookup(_ name: String) throws -> String?

  /// A short description, shown by `Sekreto.sources()`.
  func describe() -> String
}
