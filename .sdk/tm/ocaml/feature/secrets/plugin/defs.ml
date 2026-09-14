(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/defs.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The mutually recursive types: a definition's callbacks take an
   instance, an instance points at its host, and a host holds a catalog
   of definitions.

   THEY LIVE IN ONE FILE BECAUSE OCAML SAYS SO. Modules cannot be
   mutually recursive across compilation units, and this cycle is real
   rather than accidental — it is the same cycle `c` expresses with a
   forward `typedef struct Inst Inst;`. The functions over these types
   are split back out into `catalog.ml` and `host.ml`, so only the
   declarations are gathered here. *)

module V = Value

(* A scope release: a closure, so an instance's teardown captures
   whatever it needs rather than being handed a context pointer the way
   `c` must. *)
type release = unit -> unit

(* `acquire` hands back one of these so a plugin can release early; the
   scope keeps the entry, and unwinding it twice is a no-op. *)
type scope_entry = {
  sfn : release option;
  mutable done_ : bool;
  (* `acquire` and `release` both count toward `open`; a nested host's
     teardown does NOT — a teardown is not an acquisition, and the
     inner host keeps its own counter (`nest/open`). *)
  counts : bool;
}

type definition = {
  dname : string;
  mutable shape : V.t;
  (* A DEFINITION IS DATA WITH FUNCTIONS IN IT, not a class to extend.
     A document could produce one, which is the property that makes a
     catalog a data structure rather than a compile-time registry. *)
  define : (inst -> unit) option;
  activate : (inst -> unit) option;
  deactivate : (inst -> unit) option;
  close : (inst -> unit) option;
  reconfigure : (inst -> V.t -> V.t -> unit) option;
}

and catalog = { mutable defs : (string * definition) list }

and inst = {
  iref : string;
  idef : definition;
  mutable status : string;
  mutable pos : float;
  seq : float;
  mutable options : V.t;
  istate : V.t;
  mutable order : V.t;
  (* §11.4's ALWAYS-RELUCTANT rebinding, made concrete: the provider
     ref this instance's activation actually selected, per requirement
     name. Recomputing the best candidate on every question silently
     re-points a live consumer at any better-ranked newcomer, and then
     losing the provider it was really using does not restart it. *)
  mutable selected : V.t;
  (* §9.6's `active: false`. THE BAR OUTLIVES THE APPLY THAT SET IT: a
     flag consulted only while `apply` ran let a later direct `ready`
     bring the instance live, which is the config switch it exists to
     be silently ignored. *)
  mutable barred : bool;
  mutable unmet : V.t;
  mutable scope : scope_entry list;
  (* Declared in `define`, inserted only when activation SUCCEEDS
     (§8.1). Holding them until then is what makes a failed activate
     leave nothing behind. *)
  mutable bindings : Point.bound list;
  mutable inner : host option;
  (* Declared in `define`, and VISIBLE while merely `loaded` (§11):
     they are data, and hiding them would make the loaded state useless
     for introspection. *)
  exports : V.t;
  provides : V.t;
  owner : host;
}

and host = {
  hcatalog : catalog;
  reserved : V.t;
  keys : V.t;
  defaults : V.t;
  profile : V.t;
  points : V.t;
  bases : (string * (V.t -> V.t)) list;
  (* §11.3. `restart` (the default) treats provider replacement as an
     ordinary runtime operation. `hold` is the strict reading —
     deactivating a required instance is `plugin_dependency_held`. NOT
     the default, because a station that cannot swap a provider without
     a restart has lost the argument for having a plugin system. *)
  dependency : string;
  (* Set for the duration of a bulk teardown, so `held` knows this is a
     coordinated operation rather than an ad-hoc deactivation. *)
  mutable coordinated : bool;
  mutable instances : inst list;
  hlog : V.t;
  events : V.t;
  mutable seqn : float;
  mutable openc : float;
  mutable intransition : bool;
  (* WHICH callback is running, not merely that one is. §8.1 puts
     resource capture in `activate` and §8.3 says `release` outside
     `activate` is `plugin_release_scope` — and a boolean alone cannot
     tell `activate` from `define`, so it admitted an acquire in
     `define` whose scope `unload` would never unwind. *)
  mutable phase : string;
}

type hostoptions = {
  ocatalog : catalog option;
  oreserved : V.t;
  okeys : V.t;
  odefaults : V.t;
  oprofile : V.t;
  opoints : V.t;
  obases : (string * (V.t -> V.t)) list;
  odependency : string;
}

let nohostoptions =
  { ocatalog = None; oreserved = V.vnull; okeys = V.vnull;
    odefaults = V.vnull; oprofile = V.vnull; opoints = V.vnull;
    obases = []; odependency = "" }

type declarespec = {
  sdefinition : string;
  soptions : V.t option;
  sorder : V.t;
  spos : float option;
  stag : string;
  (* §9.1: set ONLY by `hostdeclare` — "the host declares those
     instances itself, after the user merge, and always wins". *)
  shostowned : bool;
}

let nospec =
  { sdefinition = ""; soptions = None; sorder = V.vnull; spos = None;
    stag = ""; shostowned = false }
