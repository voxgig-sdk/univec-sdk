// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (scala/src/Provider.scala)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// A source of secrets.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or None to mean "ask the next one". Nothing else about a
// provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file, HashiCorp Vault or a boru vault.

package com.voxgig.sekreto

trait Provider:

  /** The value, or None if this provider does not have it. */
  def lookup(name: String): Option[String]

  /** A short description, shown by `Sekreto.sources()`. */
  def describe(): String
