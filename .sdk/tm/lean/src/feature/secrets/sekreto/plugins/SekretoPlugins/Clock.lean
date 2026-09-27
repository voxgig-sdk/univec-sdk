-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Clock.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
The wall clock, and the one timestamp sekreto formats.

A PLUGIN MODULE: SigV4 is the only thing in this library that reads a
calendar, so the wall clock lives inside the aws plugin with it and the
core links neither this nor ffi/sekreto_clock.c. Token renewal wants
elapsed time rather than a date and uses `IO.monoMsNow`, which Lean has;
`renewat` is in `SekretoPlugins.Httpjson` with the other helpers the
dialing plugins share.

Lean has no wall clock at all, and SigV4 signs a `YYYYMMDDTHHMMSSZ`
stamp, so the seconds since the epoch come through a two-line binding to
libc's `time()` in ffi/sekreto_clock.c.

The CALENDAR is computed here rather than delegated to `gmtime`, so that
the arithmetic is readable and testable in Lean: it is Howard Hinnant's
days-from-civil inverse, the same algorithm every implementation of this
conversion uses.
-/

import Sekreto.Text

namespace Sekreto

/-- Seconds since the Unix epoch, UTC. -/
@[extern "sekreto_epoch_seconds"]
opaque epochseconds : IO UInt64

/-- Zero-pad a number to `width` digits. -/
private def pad (value width : Nat) : String :=
  let text := toString value
  if text.length ≥ width then text else "".pushn '0' (width - text.length) ++ text

/-- The civil date for a day count since 1970-01-01, as (year, month,
day). Hinnant's `civil_from_days`, with the era shifted so that every
intermediate stays a natural number. -/
def civilfromdays (days : Nat) : Nat × Nat × Nat :=
  let z := days + 719468
  let era := z / 146097
  let doe := z % 146097
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let year := yoe + era * 400
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let day := doy - (153 * mp + 2) / 5 + 1
  let month := if mp < 10 then mp + 3 else mp - 9
  (if month ≤ 2 then year + 1 else year, month, day)

/-- The `YYYYMMDDTHHMMSSZ` stamp SigV4 wants, for a given epoch second. -/
def awsstamp (epoch : Nat) : String :=
  let (year, month, day) := civilfromdays (epoch / 86400)
  let rest := epoch % 86400
  pad year 4 ++ pad month 2 ++ pad day 2 ++ "T" ++
    pad (rest / 3600) 2 ++ pad ((rest % 3600) / 60) 2 ++ pad (rest % 60) 2 ++ "Z"

/-- The `YYYYMMDDTHHMMSSZ` stamp SigV4 wants, for now. The only place in
this library that reads the wall clock; `sigv4` itself never does. -/
def awsnow : IO String := do
  return awsstamp (← epochseconds).toNat

end Sekreto
