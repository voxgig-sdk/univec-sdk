-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Value.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-!
# The dynamic value, and the JSON reader that fills it (§16)

NO DEPENDENCIES, not even a JSON library: §16 permits exactly one
runtime dependency (voxgig/struct) and Lean has no port of it, so the
corpus JSON is parsed here. `lakefile.lean` declares no `require`, so
`lake build` never touches the network.

AN IMMUTABLE VALUE. Lean has no mutable data at all; every field a
transition changes lives in an `IO.Ref` on the instance or the host.
That is why this port needs no in-place `refill`: a callback reads
`options` through the ref each time, so replacing what the ref holds is
the same observation the other ports get from emptying a map and
filling it again. `haskell` reaches the same arrangement for the same
reason.

A MAP PRESERVES INSERTION ORDER AND SORTS ON DEMAND. §4 rule 4 makes
order observable in several places (`keys` is sorted, `pos` is the
sorted-ref index), so both orders have to be available and the code has
to say which it means at each use.
-/

namespace Plugin

inductive Value where
  | null
  | bool (b : Bool)
  | num (n : Float)
  | str (s : String)
  | list (xs : List Value)
  /-- An association list, not a `HashMap`: insertion order must
  survive, and the maps here hold a handful of keys. -/
  | map (kvs : List (String × Value))
  deriving Inhabited

namespace Value

def isNull : Value → Bool
  | .null => true
  | _ => false

def isBool : Value → Bool
  | .bool _ => true
  | _ => false

def isNum : Value → Bool
  | .num _ => true
  | _ => false

def isStr : Value → Bool
  | .str _ => true
  | _ => false

def isList : Value → Bool
  | .list _ => true
  | _ => false

def isMap : Value → Bool
  | .map _ => true
  | _ => false

/-- `get` answers `.null` for a missing key AND for a key holding JSON
null; `has` distinguishes them, which is what §9.1's "an authored null
is not an absent key" needs. -/
def get (v : Value) (key : String) : Value :=
  match v with
  | .map kvs => match kvs.find? (fun p => p.1 == key) with
    | some p => p.2
    | none => .null
  | _ => .null

def has (v : Value) (key : String) : Bool :=
  match v with
  | .map kvs => kvs.any (fun p => p.1 == key)
  | _ => false

def set (v : Value) (key : String) (val : Value) : Value :=
  match v with
  | .map kvs =>
    if kvs.any (fun p => p.1 == key) then
      .map (kvs.map (fun p => if p.1 == key then (p.1, val) else p))
    else .map (kvs ++ [(key, val)])
  | _ => v

def del (v : Value) (key : String) : Value :=
  match v with
  | .map kvs => .map (kvs.filter (fun p => p.1 != key))
  | _ => v

def items : Value → List Value
  | .list xs => xs
  | _ => []

/-- `at` is a Lean keyword, so the index accessor is `idx`. -/
def idx (v : Value) (i : Nat) : Value :=
  match v with
  | .list xs => (xs[i]?).getD .null
  | _ => .null

def push (v : Value) (x : Value) : Value :=
  match v with
  | .list xs => .list (xs ++ [x])
  | _ => v

def len : Value → Nat
  | .list xs => xs.length
  | .map kvs => kvs.length
  | _ => 0

def asStr : Value → String
  | .str s => s
  | _ => ""

def asNum : Value → Float
  | .num n => n
  | _ => 0.0

def asBool : Value → Bool
  | .bool b => b
  | _ => false

/-- `xs` paired with positions. Lean 4.15 has no `List.zipIdx`, and
`List.enum` yields `(index, value)`; this yields `(value, index)`, which
is the order every call site here wants. -/
def indexed {α : Type} (xs : List α) : List (α × Nat) :=
  let rec go : List α → Nat → List (α × Nat)
    | [], _ => []
    | x :: r, i => (x, i) :: go r (i + 1)
  go xs 0

/-- Keys in INSERTION order. -/
def keys : Value → List String
  | .map kvs => kvs.map (·.1)
  | _ => []

/-- Merge sort, written here rather than taken from whatever the
standard library happens to expose: sortedness is CONTRACT (§4 rule 4)
and the comparison must stay visible next to the thing it orders. -/
partial def sortWith {α : Type} (le : α → α → Bool) : List α → List α
  | [] => []
  | [x] => [x]
  | xs =>
    let n := xs.length / 2
    let a := sortWith le (xs.take n)
    let b := sortWith le (xs.drop n)
    let rec merge (l r : List α) (acc : List α) : List α :=
      match l, r with
      | [], _ => acc.reverse ++ r
      | _, [] => acc.reverse ++ l
      | x :: xt, y :: yt =>
        if le x y then merge xt r (x :: acc) else merge l yt (y :: acc)
    merge a b []

def strLe (a b : String) : Bool := a < b || a == b

/-- Keys SORTED by byte order — §4 rule 4's deterministic walk. -/
def sortedKeys (v : Value) : List String := sortWith strLe (keys v)

/-- §4 rule 4: truthiness is JSON's. -/
def truthy : Value → Bool
  | .null => false
  | .bool b => b
  | .num n => n != 0.0
  | .str s => s != ""
  | _ => true

/-- Deep equality INCLUDING JSON type, which is the half that matters:
half the ports are written in languages whose `==` says `true == 1`, and
`capability/match` exists to catch exactly that. -/
partial def same (a b : Value) : Bool :=
  match a, b with
  | .null, .null => true
  | .bool x, .bool y => x == y
  | .num x, .num y => x == y
  | .str x, .str y => x == y
  | .list x, .list y =>
    x.length == y.length && (x.zip y).all (fun p => same p.1 p.2)
  | .map x, .map y =>
    x.length == y.length && x.all (fun p => has b p.1 && same p.2 (get b p.1))
  | _, _ => false

/-- Lean values are immutable, so a clone is the value itself. Kept as a
named function because every other port needs a real copy here and the
call sites should read alike. -/
def clone (v : Value) : Value := v

-- --- json ------------------------------------------------------------

/-- An integral float renders as an integer: the corpus's expected
values are written `1`, not `1.0`, and a port that emits the latter
fails every comparison for a reason that has nothing to do with the
behaviour under test. -/
def numStr (n : Float) : String :=
  if n.isFinite && n == n.round && n.abs < 1e18 then
    let i : Nat := n.abs.toUInt64.toNat
    if n < 0.0 && i != 0 then "-" ++ toString i else toString i
  else
    -- Lean's `Float.toString` is fixed to six decimals, so `1.5` renders
    -- as `1.500000` and disagrees with every other port's `json`.
    -- Trimming the trailing zeros makes them agree for every value the
    -- corpus holds; a value needing more than six decimals would be
    -- lossy in Lean's own `toString` before it reached here.
    let s := toString n
    if s.contains '.' then
      let t := (s.toList.reverse.dropWhile (· == '0')).reverse
      String.mk (if t.getLast? == some '.' then t.dropLast else t)
    else s

def hex4 (c : Nat) : String :=
  let d := fun (k : Nat) =>
    let x := (c / k) % 16
    if x < 10 then Char.ofNat (48 + x) else Char.ofNat (87 + x)
  String.mk [d 4096, d 256, d 16, d 1]

def escape (s : String) : String :=
  let esc := fun (c : Char) =>
    if c == '"' then "\\\""
    else if c == '\\' then "\\\\"
    else if c == '\n' then "\\n"
    else if c == '\r' then "\\r"
    else if c == '\t' then "\\t"
    else if c.toNat == 8 then "\\b"
    else if c.toNat == 12 then "\\f"
    else if c.toNat < 32 then "\\u" ++ hex4 c.toNat
    else String.mk [c]
  "\"" ++ String.join (s.toList.map esc) ++ "\""

/-- Canonical JSON, keys in SORTED order so two values that are `same`
render identically — the corpus compares rendered forms in places. -/
partial def json (v : Value) : String :=
  match v with
  | .null => "null"
  | .bool true => "true"
  | .bool false => "false"
  | .num n => numStr n
  | .str s => escape s
  | .list xs => "[" ++ String.intercalate "," (xs.map json) ++ "]"
  | .map _ =>
    let ks := sortedKeys v
    "{" ++ String.intercalate "," (ks.map (fun k => escape k ++ ":" ++ json (get v k))) ++ "}"

-- --- the parser ------------------------------------------------------

private def isWs (c : Char) : Bool := c == ' ' || c == '\t' || c == '\n' || c == '\r'
private def isDigit (c : Char) : Bool := '0' ≤ c && c ≤ '9'
private def isNumChar (c : Char) : Bool :=
  isDigit c || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-'

private def hexVal (c : Char) : Option Nat :=
  if isDigit c then some (c.toNat - 48)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 87)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 55)
  else none

private def skipWs (cs : List Char) : List Char := cs.dropWhile isWs

/-- The JSON number grammar, exactly. See `parseValue`'s number branch
for why loose acceptance is observable. -/
private def jsonNumber (s : String) : Bool :=
  let cs0 := s.toList
  let cs1 := if cs0.head? == some '-' then cs0.drop 1 else cs0
  match cs1 with
  | [] => false
  | c :: _ =>
    if !isDigit c then false
    else
      -- NO LEADING ZEROS: `0` consumes exactly one digit, so `01` leaves
      -- a `1` that no later branch can absorb and the token is rejected.
      let cs2 := if c == '0' then cs1.drop 1 else cs1.dropWhile isDigit
      let fracOk : Option (List Char) :=
        match cs2 with
        | '.' :: r =>
          let ds := r.takeWhile isDigit
          if ds.isEmpty then none else some (r.dropWhile isDigit)
        | _ => some cs2
      match fracOk with
      | none => false
      | some cs3 =>
        match cs3 with
        | e :: r =>
          if e == 'e' || e == 'E' then
            let r1 := if r.head? == some '+' || r.head? == some '-' then r.drop 1 else r
            let ds := r1.takeWhile isDigit
            !ds.isEmpty && (r1.dropWhile isDigit).isEmpty
          else false
        | [] => true


/-- LEAN HAS NO `String.toFloat?`, so the JSON reader parses the number
grammar itself: sign, integer part, fraction, exponent, and nothing
left over. Answers `none` rather than dying, which is what §9.5's
parse-or-string fallback needs. -/
private def digitsFloat (ds : List Char) : Float :=
  ds.foldl (fun acc c => acc * 10.0 + Float.ofNat (c.toNat - 48)) 0.0

private def digitsNat (ds : List Char) : Nat :=
  ds.foldl (fun acc c => acc * 10 + (c.toNat - 48)) 0

private def powTenNat : Nat → Float
  | 0 => 1.0
  | n + 1 => 10.0 * powTenNat n

private def powTen (e : Int) : Float :=
  if e < 0 then 1.0 / powTenNat (Int.toNat (-e)) else powTenNat (Int.toNat e)

private def strToFloat? (s : String) : Option Float :=
  let cs0 := s.toList
  let neg := cs0.head? == some '-'
  let cs1 := if neg then cs0.drop 1 else cs0
  let ip := cs1.takeWhile isDigit
  let cs2 := cs1.dropWhile isDigit
  let frac := match cs2 with
    | '.' :: r => some (r.takeWhile isDigit, r.dropWhile isDigit)
    | _ => some ([], cs2)
  match frac with
  | none => none
  | some (fp, cs3) =>
    if ip.isEmpty && fp.isEmpty then none
    else
      let expPart : Option (Int × List Char) :=
        match cs3 with
        | e :: r =>
          if e == 'e' || e == 'E' then
            let eneg := r.head? == some '-'
            let r2 := if eneg || r.head? == some '+' then r.drop 1 else r
            let ds := r2.takeWhile isDigit
            if ds.isEmpty then none
            else
              let n : Int := Int.ofNat (digitsNat ds)
              some (if eneg then -n else n, r2.dropWhile isDigit)
          else some (0, cs3)
        | [] => some (0, cs3)
      match expPart with
      | none => none
      | some (e, cs4) =>
        if !cs4.isEmpty then none
        else
          let mant := digitsFloat ip + digitsFloat fp / powTenNat fp.length
          let x := mant * powTen e
          some (if neg then -x else x)


private partial def parseStringChars (cs : List Char) (acc : List Char)
    : Except String (String × List Char) :=
  match cs with
  | [] => .error "unterminated string"
  | '"' :: rest => .ok (String.mk acc.reverse, rest)
  | '\\' :: e :: rest =>
    match e with
    | '"' => parseStringChars rest ('"' :: acc)
    | '\\' => parseStringChars rest ('\\' :: acc)
    | '/' => parseStringChars rest ('/' :: acc)
    | 'n' => parseStringChars rest ('\n' :: acc)
    | 'r' => parseStringChars rest ('\r' :: acc)
    | 't' => parseStringChars rest ('\t' :: acc)
    | 'b' => parseStringChars rest (Char.ofNat 8 :: acc)
    | 'f' => parseStringChars rest (Char.ofNat 12 :: acc)
    | 'u' =>
      match rest with
      | a :: b :: c :: d :: more =>
        match hexVal a, hexVal b, hexVal c, hexVal d with
        | some x, some y, some z, some w =>
          let hi := x * 4096 + y * 256 + z * 16 + w
          if 0xD800 ≤ hi && hi ≤ 0xDBFF then
            match more with
            | '\\' :: 'u' :: a2 :: b2 :: c2 :: d2 :: more2 =>
              match hexVal a2, hexVal b2, hexVal c2, hexVal d2 with
              | some x2, some y2, some z2, some w2 =>
                let lo := x2 * 4096 + y2 * 256 + z2 * 16 + w2
                parseStringChars more2 (Char.ofNat (0x10000 + (hi - 0xD800) * 1024 + (lo - 0xDC00)) :: acc)
              | _, _, _, _ => .error "bad \\u escape"
            | _ => parseStringChars more (Char.ofNat hi :: acc)
          else parseStringChars more (Char.ofNat hi :: acc)
        | _, _, _, _ => .error "bad \\u escape"
      | _ => .error "bad \\u escape"
    | _ => .error "bad escape"
  | c :: rest => parseStringChars rest (c :: acc)

private def parseString (cs : List Char) : Except String (String × List Char) :=
  match cs with
  | '"' :: rest => parseStringChars rest []
  | _ => .error "expected a string"

mutual

private partial def parseValue (cs0 : List Char) : Except String (Value × List Char) :=
  let cs := skipWs cs0
  match cs with
  | [] => .error "unexpected end of input"
  | 'n' :: 'u' :: 'l' :: 'l' :: rest => .ok (.null, rest)
  | 't' :: 'r' :: 'u' :: 'e' :: rest => .ok (.bool true, rest)
  | 'f' :: 'a' :: 'l' :: 's' :: 'e' :: rest => .ok (.bool false, rest)
  | '"' :: _ => do
    let (s, rest) ← parseString cs
    .ok (.str s, rest)
  | '[' :: rest => parseArray (skipWs rest) []
  | '{' :: rest => parseObject (skipWs rest) []
  | c :: _ =>
    if isNumChar c then
      -- JSON's number grammar is STRICT, and §9.5 makes that
      -- observable: env values "parse as JSON, falling back to string",
      -- so anything this reader accepts loosely silently becomes a
      -- number where the canonical keeps the authored string. `1e`,
      -- `1.`, `01`, `.5` and a bare `-` are all errors to JSON.parse;
      -- only `-0` and `1e5` are not.
      --
      --   number = [ '-' ] int [ frac ] [ exp ]
      --   int    = '0' | digit1-9 *digit
      --   frac   = '.' 1*digit
      --   exp    = ('e'|'E') [ '+' | '-' ] 1*digit
      let tok := String.mk (cs.takeWhile isNumChar)
      let rest := cs.dropWhile isNumChar
      if !jsonNumber tok then .error "bad number" else
      -- A REPORTED failure, not a crash: a bare `-` or a truncated `1e`
      -- reaches here from `Env`'s parse-or-string fallback (§9.5), and a
      -- reader that dies on a bad number rather than reporting one turns
      -- "this env value is a string" into a crash. The `ocaml` port hit
      -- this first with `float_of_string`.
      match strToFloat? tok with
      | some f => .ok (.num f, rest)
      | none => .error "bad number"
    else .error "unexpected character"

private partial def parseArray (cs : List Char) (acc : List Value)
    : Except String (Value × List Char) :=
  match cs with
  | ']' :: rest => .ok (.list acc.reverse, rest)
  | _ => do
    let (v, rest) ← parseValue cs
    match skipWs rest with
    | ',' :: more => parseArray (skipWs more) (v :: acc)
    | ']' :: more => .ok (.list (v :: acc).reverse, more)
    | _ => .error "expected , or ] in array"

private partial def parseObject (cs : List Char) (acc : List (String × Value))
    : Except String (Value × List Char) :=
  match cs with
  | '}' :: rest => .ok (.map acc.reverse, rest)
  | _ => do
    let (k, rest) ← parseString (skipWs cs)
    match skipWs rest with
    | ':' :: more => do
      let (v, rest2) ← parseValue more
      match skipWs rest2 with
      | ',' :: more2 => parseObject (skipWs more2) ((k, v) :: acc)
      | '}' :: more2 => .ok (.map ((k, v) :: acc).reverse, more2)
      | _ => .error "expected , or } in object"
    | _ => .error "expected : in object"

end

/-- Parse, or an error message. -/
def parse (text : String) : Except String Value := do
  let (v, rest) ← parseValue text.toList
  if (skipWs rest).isEmpty then .ok v else .error "trailing content"

-- --- constructors, spelled as the other ports spell them -------------

def vnull : Value := .null
def vbool (b : Bool) : Value := .bool b
def vnum (n : Float) : Value := .num n
def vstr (s : String) : Value := .str s
def vlist : Value := .list []
def vmap : Value := .map []
def ofList (xs : List Value) : Value := .list xs

end Value
end Plugin
