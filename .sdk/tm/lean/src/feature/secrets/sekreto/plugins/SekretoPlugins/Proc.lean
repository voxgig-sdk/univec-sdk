-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Proc.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
Running a child program, for the two kinds that read a secret out of one.

A PLUGIN MODULE, and the whole of this port's process handling. `boru`
and `secretspec` are read through their own CLIs; nothing in the core
spawns anything, which is half of what makes a chain of built-ins cheap.

The two plugins share this rather than each carrying a copy, the way they
share `Httpjson`: a shared support module under `plugins/` is still not a
plugin reaching into another plugin.
-/

import Sekreto.Text
import Sekreto.Core
import Sekreto.Provider

namespace Sekreto

/-- What a finished child process left behind. -/
structure Ran where
  out : String
  why : String
  status : Nat

/-- Run a child to completion and collect both its streams.

`IO.Process.output` is the right primitive and not merely a convenient
one: it closes the child's stdin (so a CLI prompting for a passphrase
sees EOF instead of hanging) and it drains stdout and stderr
CONCURRENTLY. Draining them one after the other deadlocks the moment the
child writes more than one pipe buffer - 64 KiB on Linux - to stderr, and
secretspec's box-drawn diagnostics reach that size. Nothing here sets a
timeout, so that hang would be permanent.

A binary that is not there is a store that could not answer, never a
miss: Lean reports it as exit 255 with the message below rather than as a
failure of the call itself. -/
def runcmd (command : String) (args : List String)
    (env : List (String × Option String) := []) : IO Ran := do
  let done ← tryCatch
    (IO.Process.output { cmd := command, args := args.toArray, env := env.toArray })
    (fun err => fail ("sekreto: cannot run " ++ command ++ ": " ++ why err))

  let status := done.exitCode.toNat
  let said := done.stderr.trim

  if 255 == status && hasText said "could not execute external process" then
    fail ("sekreto: cannot run " ++ command ++ ": " ++ said)

  return { out := done.stdout, why := said, status := status }

end Sekreto
