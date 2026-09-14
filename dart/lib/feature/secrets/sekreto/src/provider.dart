// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/src/provider.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// A source of secrets.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or null to mean "ask the next one". Nothing else about a
// provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file, HashiCorp Vault or a boru vault.

import 'dart:async';

abstract class Provider {
  /// The value, or null if this provider does not have it.
  ///
  /// `FutureOr` rather than `Future`, and the distinction is load-bearing.
  /// A provider that reads the environment, a file or a child process
  /// answers without yielding, and so does the chain that holds it: the
  /// whole read completes synchronously, which is what lets a caller who
  /// only ever configures local stores - the conformance suite among them -
  /// use the result directly. A provider that opens a socket answers with a
  /// Future, and the chain returns one in turn.
  ///
  /// Whichever it is, `await` reads it. A caller writes `await get(...)`
  /// once and does not care which providers are in the chain.
  FutureOr<String?> lookup(String name);

  /// A short description, shown by `Sekreto.sources()`.
  String describe();
}
