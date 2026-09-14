// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/src/com/voxgig/sekreto/Provider.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// A source of secrets.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or null to mean "ask the next one". Nothing else about a
// provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file, HashiCorp Vault or a boru vault.

package JAVAPACKAGE.feature.secrets.sekreto;

public interface Provider {

  /** The value, or null if this provider does not have it. */
  String lookup(String name);

  /** A short description, shown by `Sekreto.sources()`. */
  String describe();
}
