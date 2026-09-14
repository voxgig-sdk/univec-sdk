// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/point.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Extension points (§6). Three kinds, chosen because they are what the
 * two existing systems actually needed, and no more.
 *
 * A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
 * deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
 * undoable, but "this instance holds slot 3 of the request chain" is
 * undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
 * paper called *Listeners Considered Harmful*, and for exactly this
 * reason. */

package plugin

import "sort"

type Kind string

const (
	KindHook     Kind = "hook"
	KindChain    Kind = "chain"
	KindProvider Kind = "provider"
)

// Mode is §6.1: "fan-out" is not one answer but four. In a language with
// asynchrony, "call every binding" hides a decision — start them all and
// wait, await each in turn, or do not wait — and a design that leaves it
// unsaid gets four different answers from four ports, in the concurrency
// behaviour of production code no corpus entry happens to cover.
type Mode string

const (
	ModeEmit     Mode = "emit"
	ModeParallel Mode = "parallel"
	ModeSerial   Mode = "serial"
	ModeBail     Mode = "bail"
)

/* BindFn IS ONE TYPE FOR ALL THREE KINDS, AND THAT IS A PORT DECISION
 * WORTH STATING.
 *
 * The canonical calls `fn(arg)` for a hook, `fn(next, ...args)` for a
 * chain and `fn(...args)` for a provider — three arities on one
 * untyped slot. Go could give each kind its own func type, but then
 * `bind` needs three spellings and a probe that binds the same
 * function to a hook point in one corpus entry and a provider point in
 * the next (which `point/bail` and `point/provider` do, with the same
 * `provider` probe) could not be written at all.
 *
 * So one variadic signature carries all three, and a chain's `next` is
 * simply its first argument — exactly as in the canonical.
 *
 * A BINDING CANNOT RAISE IN GO. It RETURNS an error value instead, and
 * §6.1's collecting modes gather those. */
type BindFn func(args ...any) any

type Spec struct {
	Kind Kind `json:"kind,omitempty"`
	Mode Mode `json:"mode,omitempty"`
	// Base is `chain` only: the host owns the base, and a plugin cannot
	// replace it (§6.2). One that wants to SUBSTITUTE rather than wrap
	// binds innermost and simply does not call `next`.
	Base BindFn `json:"-"`
	// Exclusive is `provider` only: a second binding is an error rather
	// than a shadow.
	Exclusive bool `json:"exclusive,omitempty"`
	// Default is `provider` only: the host's fallback.
	Default any `json:"default,omitempty"`
	Pin     Pin `json:"pin,omitempty"`
}

type Bound struct {
	Ref   string
	Point string
	Fn    BindFn
	// Band: `provider` ranks by HIGHEST band, unlike hook and chain
	// which run lowest first. Kept as declared so the two rules stay
	// visibly different rather than one being derived from the other by
	// a reader who then gets it backwards.
	Band int
}

// Emit is fan-out. Return values are ignored except in `bail`.
//
// The second return is the canonical's synchronous throw under
// `mode: emit`; the first is the collected error list under the
// gathering modes, and the bailing value under `bail`.
func Emit(bindings []Bound, mode Mode, arg any) (any, error) {
	if ModeBail == mode {
		// Stops at the first binding that RETURNS A VALUE — the
		// "handled, stop" case. A NIL RETURN DECLINES (§6.1): go has one
		// way to say nothing, and the model's rule is written to that
		// rather than to JavaScript's null/undefined pair.
		for _, b := range bindings {
			if v := b.Fn(arg); nil != v {
				if err, bad := v.(error); bad {
					return nil, err
				}
				return v, nil
			}
		}
		return nil, nil
	}

	errors := []any{}
	for _, b := range bindings {
		v := b.Fn(arg)
		err, bad := v.(error)
		if !bad {
			continue
		}
		// `emit` raises synchronously; the collecting modes gather.
		if ModeEmit == mode {
			return nil, err
		}
		errors = append(errors, err)
	}
	if ModeEmit == mode {
		return nil, nil
	}
	return errors, nil
}

// Compose is b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2).
//
// Recomputed by the host whenever the live set changes, and cached
// between changes. Plugins receive `next` as an argument; they never see
// or store the previous value of anything. A plugin that stashes `next`
// and calls it after deactivation is a bug the host cannot prevent, and
// this says so rather than pretending otherwise.
func Compose(bindings []Bound, base BindFn) BindFn {
	next := base
	for i := len(bindings) - 1; 0 <= i; i-- {
		fn := bindings[i].Fn
		inner := next
		next = func(args ...any) any {
			return fn(append([]any{inner}, args...)...)
		}
	}
	return next
}

type Picked struct {
	Winner   *Bound
	Shadowed []string
}

// Provider selects at most one live implementation (§6.3). The winner is
// the highest band, ties broken by ref sort, and THE LOSERS ARE VISIBLE
// rather than silently ignored.
func Provider(bindings []Bound, spec Spec) (Picked, error) {
	if 0 == len(bindings) {
		return Picked{Shadowed: []string{}}, nil
	}

	if spec.Exclusive && 1 < len(bindings) {
		refs := []string{}
		for _, b := range bindings {
			refs = append(refs, b.Ref)
		}
		sort.Strings(refs)
		return Picked{}, Fail("plugin_point_exclusive",
			"point is exclusive and has "+itoa(len(bindings))+" bindings: "+
				join(refs, ", "),
			map[string]any{"refs": refs})
	}

	ranked := append([]Bound{}, bindings...)
	sort.SliceStable(ranked, func(i, j int) bool {
		a, b := ranked[i], ranked[j]
		if a.Band != b.Band {
			return a.Band > b.Band // HIGHEST band wins
		}
		return a.Ref < b.Ref
	})

	shadowed := []string{}
	for _, b := range ranked[1:] {
		shadowed = append(shadowed, b.Ref)
	}
	winner := ranked[0]
	return Picked{Winner: &winner, Shadowed: shadowed}, nil
}
