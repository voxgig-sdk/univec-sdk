// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/point.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package plugin

import "sort"

type Kind string

const (
	KindHook     Kind = "hook"
	KindChain    Kind = "chain"
	KindProvider Kind = "provider"
)

type Mode string

const (
	ModeEmit     Mode = "emit"
	ModeParallel Mode = "parallel"
	ModeSerial   Mode = "serial"
	ModeBail     Mode = "bail"
)

type BindFn func(args ...any) any

type Spec struct {
	Kind Kind `json:"kind,omitempty"`
	Mode Mode `json:"mode,omitempty"`
	// Base is `chain` only: the host owns the base, and a plugin cannot
	// replace it (§6.2). One that wants to SUBSTITUTE rather than wrap
	// binds innermost and simply does not call `next`.
	Base      BindFn `json:"-"`
	Exclusive bool   `json:"exclusive,omitempty"`
	Default   any    `json:"default,omitempty"`
	Pin       Pin    `json:"pin,omitempty"`
}

type Bound struct {
	Ref   string
	Point string
	Fn    BindFn
	Band  int
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
			return a.Band > b.Band
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
