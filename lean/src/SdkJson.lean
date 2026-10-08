/- JSON reader: String -> struct `Value`.
   The runtime parses HTTP response bodies into the vendored voxgig-struct
   `Value` model (VoxgigStruct.lean), so specs/options/payloads/results are all
   the same reference-stable node type — exactly as the Python/Go SDKs pass
   `map[string]any` around. Serialisation back to a String is `stringify`
   (VoxgigStruct). -/

import VoxgigStruct

open VoxgigStruct

namespace SdkJson

structure JState where
  src : Array Char
  pos : Nat

partial def jPeek (s : JState) : Option Char := s.src[s.pos]?

partial def jSkipWs (s : JState) : JState := Id.run do
  let mut p := s.pos
  while p < s.src.size &&
      (s.src[p]! == ' ' || s.src[p]! == '\t' || s.src[p]! == '\n' || s.src[p]! == '\r') do
    p := p + 1
  return { s with pos := p }

partial def jStr (s0 : JState) : SIO (String × JState) := do
  let src := s0.src
  let mut p := s0.pos + 1
  let mut b := ""
  repeat do
    if p >= src.size then break
    let c := src[p]!
    p := p + 1
    if c == '"' then break
    if c == '\\' then
      let e := src[p]!
      p := p + 1
      match e with
      | '"' => b := b.push '"'
      | '\\' => b := b.push '\\'
      | '/' => b := b.push '/'
      | 'n' => b := b.push '\n'
      | 't' => b := b.push '\t'
      | 'r' => b := b.push '\r'
      | 'b' => b := b.push '\x08'
      | 'f' => b := b.push '\x0c'
      | 'u' => do
        let mut code : Nat := 0
        for _ in [0:4] do
          let h := src[p]!
          p := p + 1
          let d :=
            if h >= '0' && h <= '9' then h.toNat - '0'.toNat
            else if h >= 'a' && h <= 'f' then 10 + h.toNat - 'a'.toNat
            else if h >= 'A' && h <= 'F' then 10 + h.toNat - 'A'.toNat
            else 0
          code := code * 16 + d
        b := b.push (Char.ofNat code)
      | c => b := b.push c
    else
      b := b.push c
  return (b, { s0 with pos := p })

mutual

partial def jVal (s0 : JState) : SIO (Value × JState) := do
  let s := jSkipWs s0
  match jPeek s with
  | some '{' => jObj s
  | some '[' => jArr s
  | some '"' => do
    let (str, s') ← jStr s
    pure (.str str, s')
  | some 't' => pure (.bool true, { s with pos := s.pos + 4 })
  | some 'f' => pure (.bool false, { s with pos := s.pos + 5 })
  | some 'n' => pure (.null, { s with pos := s.pos + 4 })
  | _ => jNum s

partial def jObj (s0 : JState) : SIO (Value × JState) := do
  let s := jSkipWs { s0 with pos := s0.pos + 1 }
  if jPeek s == some '}' then
    pure (← emptyMap, { s with pos := s.pos + 1 })
  else do
    let m ← emptyMap
    let sRef ← IO.mkRef s
    repeat do
      let s1 := jSkipWs (← sRef.get)
      let (k, s2) ← jStr s1
      let s3 := jSkipWs s2
      let s4 := { s3 with pos := s3.pos + 1 }  -- ':'
      let (v, s5) ← jVal s4
      let _ ← setprop m (.str k) v
      let s6 := jSkipWs s5
      let c := (jPeek s6).getD '}'
      sRef.set { s6 with pos := s6.pos + 1 }
      if c != ',' then break
    pure (m, ← sRef.get)

partial def jArr (s0 : JState) : SIO (Value × JState) := do
  let s := jSkipWs { s0 with pos := s0.pos + 1 }
  if jPeek s == some ']' then
    pure (← emptyList, { s with pos := s.pos + 1 })
  else do
    let sRef ← IO.mkRef s
    let accRef ← IO.mkRef (#[] : Array Value)
    repeat do
      let (v, s1) ← jVal (← sRef.get)
      accRef.modify (·.push v)
      let s2 := jSkipWs s1
      let c := (jPeek s2).getD ']'
      sRef.set { s2 with pos := s2.pos + 1 }
      if c != ',' then break
    pure (← newList (← accRef.get), ← sRef.get)

partial def jNum (s0 : JState) : SIO (Value × JState) := do
  let src := s0.src
  let mut p := s0.pos
  let start := p
  while p < src.size &&
      (let c := src[p]!
       (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') do
    p := p + 1
  let tok := String.ofList (src.extract start p).toList
  pure (.num ((parseFloatJS tok).getD 0.0), { s0 with pos := p })

end

-- A strict check, apart from the reader above, which accepts what it can:
-- each returns the position after what it read, or none.

partial def vWs (a : Array Char) (p : Nat) : Nat :=
  if p < a.size && (a[p]! == ' ' || a[p]! == '\t' || a[p]! == '\n' || a[p]! == '\r')
  then vWs a (p + 1) else p

partial def vDigits (a : Array Char) (p : Nat) : Nat :=
  if p < a.size && a[p]!.isDigit then vDigits a (p + 1) else p

def vLit (a : Array Char) (p : Nat) (w : String) : Option Nat :=
  let cs := w.toList
  if p + cs.length <= a.size && (a.extract p (p + cs.length)).toList == cs
  then some (p + cs.length) else none

def isHex (c : Char) : Bool :=
  c.isDigit || ('a' <= c && c <= 'f') || ('A' <= c && c <= 'F')

partial def vStrFrom (a : Array Char) (q : Nat) : Option Nat :=
  if q >= a.size then none
  else
    let c := a[q]!
    if c == '"' then some (q + 1)
    else if c == '\\' then
      if q + 1 >= a.size then none
      else
        let e := a[q + 1]!
        if e == 'u' then
          if q + 6 <= a.size && ((List.range 4).all fun i => isHex a[q + 2 + i]!)
          then vStrFrom a (q + 6) else none
        else if "\"\\/bfnrt".toList.contains e then vStrFrom a (q + 2)
        else none
    else if c.toNat < 0x20 then none
    else vStrFrom a (q + 1)

def vNum (a : Array Char) (p : Nat) : Option Nat := Id.run do
  let mut q := p
  if q < a.size && a[q]! == '-' then q := q + 1
  let d := vDigits a q
  if d == q then return none
  q := d
  if q < a.size && a[q]! == '.' then
    let f := vDigits a (q + 1)
    if f == q + 1 then return none
    q := f
  if q < a.size && (a[q]! == 'e' || a[q]! == 'E') then
    q := q + 1
    if q < a.size && (a[q]! == '+' || a[q]! == '-') then q := q + 1
    let e := vDigits a q
    if e == q then return none
    q := e
  return some q

mutual

partial def vVal (a : Array Char) (p0 : Nat) : Option Nat :=
  let p := vWs a p0
  if p >= a.size then none
  else match a[p]! with
    | '{' =>
      let q := vWs a (p + 1)
      if q < a.size && a[q]! == '}' then some (q + 1) else vMembers a q
    | '[' =>
      let q := vWs a (p + 1)
      if q < a.size && a[q]! == ']' then some (q + 1) else vItems a q
    | '"' => vStrFrom a (p + 1)
    | 't' => vLit a p "true"
    | 'f' => vLit a p "false"
    | 'n' => vLit a p "null"
    | _ => vNum a p

partial def vMembers (a : Array Char) (p0 : Nat) : Option Nat := do
  let p := vWs a p0
  guard (p < a.size && a[p]! == '"')
  let k ← vStrFrom a (p + 1)
  let c := vWs a k
  guard (c < a.size && a[c]! == ':')
  let v ← vVal a (c + 1)
  let s := vWs a v
  if s < a.size && a[s]! == ',' then vMembers a (s + 1)
  else if s < a.size && a[s]! == '}' then some (s + 1)
  else none

partial def vItems (a : Array Char) (p0 : Nat) : Option Nat := do
  let v ← vVal a p0
  let s := vWs a v
  if s < a.size && a[s]! == ',' then vItems a (s + 1)
  else if s < a.size && a[s]! == ']' then some (s + 1)
  else none

end

/-- Whether `s` holds exactly one JSON value, whitespace aside. -/
def jsonValid (s : String) : Bool :=
  let a := s.toList.toArray
  match vVal a 0 with
  | some p => vWs a p == a.size
  | none => false

/-- Parse a JSON string into a struct `Value` (empty/blank input -> noval). -/
def jsonRead (s : String) : SIO Value := do
  if s.all (fun c => c == ' ' || c == '\n' || c == '\t' || c == '\r') then pure .noval
  else pure (← jVal { src := s.toList.toArray, pos := 0 }).1

end SdkJson
