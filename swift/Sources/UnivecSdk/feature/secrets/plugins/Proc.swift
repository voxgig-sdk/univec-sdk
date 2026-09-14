// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/plugins/Proc.swift)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Running a child process, for the two provider kinds that read a vault
// through its own CLI.
//
// Under plugins/ rather than in the core for the same reason the HTTP
// round-trip is: a built-in kind reads at most a local file, and spawning
// a process is a long way past that line.
//
// A port of the child-process halves of typescript/plugins/boru.ts and
// typescript/plugins/secretspec.ts, which are canonical.

import Dispatch
import Foundation

import Sekreto

/// Where a command lives, searched along PATH. `Process` on Linux takes a
/// path, not a name, so the search a shell would do is done here.
func findcommand(_ command: String, _ environment: [String: String]) -> String? {
  if command.contains("/") {
    return FileManager.default.isExecutableFile(atPath: command) ? command : nil
  }

  for dir in (environment["PATH"] ?? "").components(separatedBy: ":") {
    let candidate = dir.isEmpty ? command : dir + "/" + command
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }

  return nil
}

/// What a finished child process left behind.
struct Ran {
  let out: String
  let why: String
  let status: Int32
}

/// Run a child to completion and collect both its streams.
///
/// The two streams are drained CONCURRENTLY. Reading stdout to EOF and
/// only then reading stderr deadlocks the moment the child writes more
/// than one pipe buffer (64 KiB on Linux) to stderr: the parent is blocked
/// waiting for stdout, the child is blocked waiting for room on stderr,
/// and neither can move. Nothing in this library sets a timeout, so that
/// hang is permanent - `get()` simply never returns. secretspec's
/// diagnostics are box-drawn and reach that size easily.
///
/// The child's stdin is the null device rather than a pipe nobody writes
/// to, so a CLI that reads it - one prompting for a passphrase when its
/// environment variable is absent - sees EOF and gives up instead of
/// waiting forever.
///
/// The argument list is passed as an array, never through a shell, and no
/// secret is ever put on a command line where the process table publishes
/// it.
func runcmd(_ argv: [String], _ environment: [String: String], _ command: String) throws -> Ran {
  // Resolved here rather than through `/usr/bin/env`, so that "this
  // binary is not installed" stays a `cannot run` error instead of
  // arriving as a non-zero exit that the miss detection would then have
  // to reason about.
  guard let binary = findcommand(argv[0], environment) else {
    throw SekretoError("sekreto: cannot run \(command): no such file or directory")
  }

  let process = Process()

  process.executableURL = URL(fileURLWithPath: binary)
  process.arguments = Array(argv.dropFirst())
  process.environment = environment

  let outpipe = Pipe()
  let errpipe = Pipe()

  process.standardInput = FileHandle.nullDevice
  process.standardOutput = outpipe
  process.standardError = errpipe

  do {
    try process.run()
  } catch {
    throw SekretoError("sekreto: cannot run \(command): \(why(error))")
  }

  var errdata = Data()
  let drained = DispatchSemaphore(value: 0)

  DispatchQueue.global().async {
    errdata = errpipe.fileHandleForReading.readDataToEndOfFile()
    drained.signal()
  }

  let outdata = outpipe.fileHandleForReading.readDataToEndOfFile()

  process.waitUntilExit()
  drained.wait()

  return Ran(
    out: String(decoding: outdata, as: UTF8.self),
    why: String(decoding: errdata, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
    status: process.terminationStatus
  )
}
