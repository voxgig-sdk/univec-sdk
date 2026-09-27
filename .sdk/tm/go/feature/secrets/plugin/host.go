// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/host.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package plugin

import (
	"fmt"
	"sort"
	"sync"
)

type PointSpec = Spec

type HostOptions struct {
	Catalog    *Catalog
	Reserved   []string
	Keys       Keys
	Defaults   map[string]any
	Profile    string
	Points     map[string]Spec
	Dependency string
}

// Live is one instance's record. The exported half is what
// introspection reads; the rest is the host's.
type Live struct {
	Ref     string
	Status  Status
	Pos     int
	Seq     int
	Options map[string]any
	State   map[string]any
	// Inner is set when this instance is itself a host (§6.5).
	Inner *Host

	def      Definition
	order    *OrderBlock
	selected map[string]string
	// barred is §9.6's `active: false` — "declares it and bars it: it
	// appears in `host.list()`, and `activate` and `ready` on it fail
	// rather than quietly doing nothing". THE BAR OUTLIVES THE APPLY
	// THAT SET IT: a flag consulted only while `apply` ran let a later
	// direct `Ready` bring the instance live.
	barred bool
	unmet  []string
	// scope holds the resources the instance scope holds, newest last —
	// unwound in REVERSE, because that is the only order in which
	// teardown mirrors setup (§8.3).
	scope []func()
	// bindings are declared in `define`, inserted only when activation
	// SUCCEEDS (§8.1). Holding them until then is what makes a failed
	// activate leave nothing behind.
	bindings []Bound
	// exports are declared in `define`, and VISIBLE while merely
	// `loaded` (§11): they are data, and hiding them would make the
	// loaded state useless for introspection.
	exports  map[string]any
	provides []Provided
}

type Event struct {
	Ref    string `json:"ref"`
	Event  string `json:"event"`
	Seq    int    `json:"seq"`
	Status Status `json:"status"`
}

type Observable struct {
	Status map[string]Status `json:"status"`
	Open   int               `json:"open"`
	Log    []string          `json:"log"`
	Result any               `json:"result"`
}

type Host struct {
	opts       HostOptions
	catalog    *Catalog
	reserved   []string
	points     map[string]Spec
	dependency string

	// coordinated is set for the duration of a bulk teardown, so `held`
	// knows this is a coordinated operation rather than an ad-hoc
	// deactivation.
	coordinated bool

	mu sync.Mutex

	inst map[string]*Live
	log  []string
	// events is §14: the lifecycle event record. `seq` distinguishes ONE
	// INCARNATION of stripe$test from the next, which is the whole
	// reason it is not `pos` (§4 rule 4).
	events       []Event
	seqn         int
	open         int
	intransition bool
	phase        string
}

func MakeHost(options HostOptions) *Host {
	h := &Host{
		opts:       options,
		catalog:    options.Catalog,
		reserved:   options.Reserved,
		points:     options.Points,
		dependency: or(options.Dependency, "restart"),
		inst:       map[string]*Live{},
		log:        []string{},
		events:     []Event{},
	}
	if nil == h.catalog {
		h.catalog, _ = MakeCatalog()
	}
	if nil == h.points {
		h.points = map[string]Spec{}
	}
	return h
}

func (h *Host) Catalog() *Catalog { return h.catalog }

// --- observation -----------------------------------------------------

func (h *Host) List() map[string]Status {
	out := map[string]Status{}
	for _, r := range sortedkeys(h.inst) {
		out[r] = h.inst[r].Status
	}
	return out
}

// Instance is the introspection lookup. A MALFORMED REF IS
// `plugin_bad_name` HERE TOO: the canonical calls `canonref`, which
// raises, and a port that swallowed the parse failure answered the
// ordinary "no such instance" instead — a different answer to a
// different question. `nil, nil` is the well-formed-but-absent case.
func (h *Host) Instance(ref string) (*Live, error) {
	r, err := CanonRef(ref)
	if nil != err {
		return nil, err
	}
	return h.inst[r], nil
}

func (h *Host) Trace() []Event { return append([]Event{}, h.events...) }

func (h *Host) Observable(result any) Observable {
	return Observable{
		Status: h.List(),
		Open:   h.open,
		Log:    append([]string{}, h.log...),
		Result: result,
	}
}

// --- the state machine -----------------------------------------------

func (h *Host) guard() error {
	if h.intransition {
		return Fail("plugin_reentrant",
			"transition attempted from inside a lifecycle callback", nil)
	}
	return nil
}

func (h *Host) enter() (func(), error) {
	if h.mu.TryLock() {
		return h.mu.Unlock, nil
	}
	if err := h.guard(); nil != err {
		return nil, err
	}
	h.mu.Lock()
	return h.mu.Unlock, nil
}

func (h *Host) need(ref string) (*Live, error) {
	r, err := CanonRef(ref)
	if nil != err {
		return nil, err
	}
	e := h.inst[r]
	if nil == e {
		return nil, Fail("plugin_not_loaded", "no such instance: "+r,
			map[string]any{"ref": r})
	}
	return e, nil
}

func (h *Host) checkreserved(ref string) error {
	return checkreservedref(ref, h.reserved)
}

func (h *Host) run(e *Live, fn func(*Inst) error, at string) error {
	h.log = append(h.log, e.Ref+":"+at)
	h.events = append(h.events, Event{Ref: e.Ref, Event: at, Seq: e.Seq, Status: e.Status})
	if nil == fn {
		return nil
	}
	h.intransition = true
	h.phase = at
	defer func() { h.intransition = false; h.phase = "" }()
	err := fn(h.api(e))
	if nil == err {
		return nil
	}
	if "" != CodeOf(err) {
		return err
	}
	return Fail("plugin_"+at+"_failed",
		e.Ref+" raised in "+at+": "+err.Error(),
		map[string]any{"ref": e.Ref, "cause": err.Error()})
}

type Inst struct {
	h *Host
	e *Live
}

func (h *Host) api(e *Live) *Inst { return &Inst{h: h, e: e} }

func (i *Inst) Ref() string             { return i.e.Ref }
func (i *Inst) Name() string            { return refname(i.e.Ref) }
func (i *Inst) Tag() string             { r, _ := ParseRef(i.e.Ref); return r.Tag }
func (i *Inst) Options() map[string]any { return i.e.Options }
func (i *Inst) State() map[string]any   { return i.e.State }
func (i *Inst) Host() *Host             { return i.h }

// Release registers a foreign resource the host did not hand out (§8.3);
// host calls are recorded automatically.
func (i *Inst) Release(fn func()) error {
	// §8.3: "`inst.release` outside `activate` is
	// `plugin_release_scope`". `intransition` is true in `define` too,
	// and a scope entry registered there is never unwound.
	if "activate" != i.h.phase {
		return Fail("plugin_release_scope", "release called outside activate", nil)
	}
	// SYMMETRIC WITH Acquire, and it has to be: `open` counts the
	// resources CURRENTLY HELD, so an entry that is registered and then
	// unwound must leave the count where it found it.
	done := false
	h := i.h
	i.e.scope = append(i.e.scope, func() {
		if !done {
			done = true
			h.open -= 1
			fn()
		}
	})
	h.open += 1
	return nil
}

func (i *Inst) Acquire() (func(), error) {
	// §8.1: resources are "acquired during `activate` — the scope's
	// actual job". Same reason as `Release` above.
	if "activate" != i.h.phase {
		return nil, Fail("plugin_release_scope", "acquire called outside activate", nil)
	}
	done := false
	h := i.h
	rel := func() {
		if !done {
			done = true
			h.open -= 1
		}
	}
	i.e.scope = append(i.e.scope, rel)
	h.open += 1
	return rel, nil
}

func (i *Inst) Bind(point string, fn BindFn, band int) error {
	if "define" != i.h.phase {
		return Fail("plugin_bind_scope", "bind called outside define: "+point,
			map[string]any{"ref": i.e.Ref, "point": point})
	}
	if _, ok := i.h.points[point]; !ok {
		return Fail("plugin_point_unknown", "no such point: "+point,
			map[string]any{"point": point})
	}
	i.e.bindings = append(i.e.bindings, Bound{Ref: i.e.Ref, Point: point, Fn: fn, Band: band})
	return nil
}

// Export publishes a value for other plugins and for the application
// (§11).
func (i *Inst) Export(key string, value any) { i.e.exports[key] = value }

// Provides declares what this instance can do for others (§11.1).
func (i *Inst) Provides(p Provided) { i.e.provides = append(i.e.provides, p) }

func (i *Inst) Capability(name string) string {
	for _, req := range Requirements(i.e.Options) {
		if req.Name == name {
			return i.h.chosen(i.e, req, true)
		}
	}
	return ""
}

type Position struct {
	Index     int  `json:"index"`
	Count     int  `json:"count"`
	Outermost bool `json:"outermost"`
	Innermost bool `json:"innermost"`
}

func (i *Inst) Position(point string) (Position, error) {
	return i.h.PositionOf(i.e.Ref, point)
}

/* Nest: AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS
 * THE INNER ONE'S LIFETIME. Registering the teardown in the instance
 * scope is what makes that true rather than aspirational: the inner host
 * closes when the outer instance deactivates, in the same reverse unwind
 * as every other resource. */
func (i *Inst) Nest(nestopts HostOptions) (*Host, error) {
	if !i.h.intransition {
		return nil, Fail("plugin_release_scope", "nest called outside a lifecycle callback", nil)
	}
	inner := MakeHost(nestopts)
	i.e.scope = append(i.e.scope, func() { inner.Close() })
	i.e.Inner = inner
	return inner, nil
}

func (h *Host) AutoTag(name string) (string, error) {
	for n := 1; ; n++ {
		cand, err := FormatRef(name, itoa(n))
		if nil != err {
			return "", err
		}
		if _, taken := h.inst[cand]; !taken {
			return cand, nil
		}
	}
}

type DeclareSpec struct {
	Definition string
	Options    map[string]any
	Order      *OrderBlock
	Pos        *int
	Tag        string
	// HostOwned is §9.1: "The host declares those instances itself,
	// after the user merge, and always wins." Set ONLY by HostDeclare.
	HostOwned bool
}

func (h *Host) Declare(ref string, spec DeclareSpec) (*Live, error) {
	leave, err := h.enter()
	if nil != err {
		return nil, err
	}
	defer leave()
	return h.declare(ref, spec)
}

// declare and its siblings are the UNLOCKED bodies. The public
// transitions call each other — `ready` walks declare/load/activate,
// `apply` walks all four — and a Go mutex is not reentrant, so the lock
// is taken once at the door and never again below it.
func (h *Host) declare(ref string, spec DeclareSpec) (*Live, error) {
	if "?" == spec.Tag {
		r, err := CanonRef(ref)
		if nil != err {
			return nil, err
		}
		ref, err = h.AutoTag(refname(r))
		if nil != err {
			return nil, err
		}
	}
	r, err := CanonRef(ref)
	if nil != err {
		return nil, err
	}
	if !spec.HostOwned {
		if err := h.checkreserved(r); nil != err {
			return nil, err
		}
	}
	defname := or(spec.Definition, refname(r))
	def, ok := h.catalog.Get(defname)
	if !ok {
		return nil, Fail("plugin_unknown_definition", "not in catalog: "+defname,
			map[string]any{"name": defname})
	}

	if existing := h.inst[r]; nil != existing {
		// §4 rule 1: a pair addresses at most one instance. Re-declaring
		// the SAME definition is the idempotent case; a different one is
		// a duplicate, not a silent overwrite (seneca) and not an
		// impossibility (sdkgen).
		if existing.def.Name != def.Name {
			return nil, Fail("plugin_ref_duplicate", "instance already declared: "+r,
				map[string]any{"ref": r})
		}
		return existing, nil
	}

	pos := len(h.inst)
	if nil != spec.Pos {
		pos = *spec.Pos
	}
	options := spec.Options
	if nil == options {
		options = map[string]any{}
	}
	e := &Live{
		Ref: r, def: def, Status: StatusDeclared,
		Pos: pos, Seq: h.seqn,
		Options:  options,
		State:    map[string]any{},
		selected: map[string]string{},
		order:    spec.Order, unmet: []string{}, scope: []func(){},
		bindings: []Bound{}, exports: map[string]any{}, provides: []Provided{},
	}
	h.seqn++
	h.inst[r] = e
	return e, nil
}

func (h *Host) HostDeclare(ref string, spec DeclareSpec) (*Live, error) {
	leave, err := h.enter()
	if nil != err {
		return nil, err
	}
	defer leave()
	spec.HostOwned = true
	return h.declare(ref, spec)
}

func (h *Host) Load(ref string, spec DeclareSpec) (*Live, error) {
	leave, err := h.enter()
	if nil != err {
		return nil, err
	}
	defer leave()
	return h.load(ref, spec)
}

func (h *Host) load(ref string, spec DeclareSpec) (*Live, error) {
	e, err := h.declare(ref, spec)
	if nil != err {
		return nil, err
	}
	if StatusDeclared != e.Status {
		return e, nil // idempotent in the trivial direction
	}
	if nil != spec.Options {
		e.Options = spec.Options
	}
	if err := h.run(e, e.def.Define, "define"); nil != err {
		e.Status = StatusFailed
		return nil, err
	}
	e.Status = StatusLoaded

	if err := CheckCycle(h.graphnodes()); nil != err {
		e.Status = StatusFailed
		return nil, err
	}
	return e, nil
}

func (h *Host) graphnodes() []DependNode {
	out := []DependNode{}
	for _, r := range sortedkeys(h.inst) {
		names := []string{}
		for _, p := range h.inst[r].provides {
			names = append(names, p.Name)
		}
		out = append(out, DependNode{
			Ref: r, Provides: names, Requires: Requirements(h.inst[r].Options)})
	}
	return out
}

func (h *Host) Activate(ref string) (*Live, error) {
	leave, err := h.enter()
	if nil != err {
		return nil, err
	}
	defer leave()
	return h.activate(ref)
}

func (h *Host) activate(ref string) (*Live, error) {
	e, err := h.need(ref)
	if nil != err {
		return nil, err
	}
	if StatusLive == e.Status {
		return e, nil // no-op returning success
	}
	if StatusFailed == e.Status {
		return nil, Fail("plugin_bad_state", "instance has failed: "+e.Ref,
			map[string]any{"ref": e.Ref})
	}
	// §9.6: `active: false` bars the instance from running, and the bar
	// is on the INSTANCE rather than on the apply that set it. `Ready`
	// reaches this through `activate`, so one guard covers both verbs
	// the design names.
	if e.barred {
		return nil, Fail("plugin_inactive",
			"instance is barred by active: false: "+e.Ref,
			map[string]any{"ref": e.Ref})
	}
	if StatusDeclared == e.Status {
		if _, err := h.load(e.Ref, DeclareSpec{}); nil != err {
			return nil, err
		}
	}

	if unmet := h.unmetof(e); 0 < len(unmet) {
		e.unmet = unmet
		e.Status = StatusPending
		return e, nil
	}

	if err := h.run(e, e.def.Activate, "activate"); nil != err {
		// Unwind whatever the partial activation captured, in reverse.
		h.unwind(e)
		e.Status = StatusFailed
		return nil, err
	}
	// §11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
	// later question — the cascade, `hold`, `unmet` — reads it back
	// rather than re-ranking, which is what "always-reluctant" means.
	for _, r := range Requirements(e.Options) {
		h.chosen(e, r, true)
	}
	e.Status = StatusLive
	h.reconcile()
	return e, nil
}

func (h *Host) Deactivate(ref string) (*Live, error) {
	leave, err := h.enter()
	if nil != err {
		return nil, err
	}
	defer leave()
	return h.deactivate(ref)
}

func (h *Host) deactivate(ref string) (*Live, error) {
	e, err := h.need(ref)
	if nil != err {
		return nil, err
	}
	if StatusLoaded == e.Status || StatusDeclared == e.Status {
		return e, nil
	}

	// §5.2: `Unload` is THE ONLY TRANSITION OUT OF `failed`.
	if StatusFailed == e.Status {
		return nil, Fail("plugin_bad_state", "instance has failed: "+e.Ref,
			map[string]any{"ref": e.Ref})
	}

	if StatusPending == e.Status {
		e.Status = StatusLoaded
		e.unmet = []string{}
		return e, nil
	}

	if err := h.held(e); nil != err {
		return nil, err
	}
	h.cascade(e, map[string]bool{})

	if err := h.run(e, e.def.Deactivate, "deactivate"); nil != err {
		h.unwind(e)
		e.Status = StatusFailed
		return nil, err
	}
	if err := h.releasecheck(e, h.unwind(e)); nil != err {
		return nil, err
	}
	e.Status = StatusLoaded
	h.reconcile()
	return e, nil
}

func (h *Host) Unload(ref string) error {
	leave, err := h.enter()
	if nil != err {
		return err
	}
	defer leave()
	return h.unload(ref)
}

func (h *Host) unload(ref string) error {
	e, err := h.need(ref)
	if nil != err {
		return err
	}
	if StatusLive == e.Status || StatusPending == e.Status {
		if StatusLive == e.Status {
			if err := h.held(e); nil != err {
				return err
			}
			h.cascade(e, map[string]bool{})
			if err := h.run(e, e.def.Deactivate, "deactivate"); nil != err {
				// §5.2: ANY failure during a transition lands the
				// instance in `failed`, with the scope STILL FULLY
				// UNWOUND — and the instance STAYS REGISTERED, because
				// `failed` is a state an operator has to be able to see.
				h.unwind(e)
				e.Status = StatusFailed
				return err
			}
			if err := h.releasecheck(e, h.unwind(e)); nil != err {
				return err
			}
		}
		e.Status = StatusLoaded
	}
	if StatusLoaded == e.Status || StatusFailed == e.Status {
		err := h.run(e, e.def.Close, "close")
		delete(h.inst, e.Ref)
		return err
	}
	delete(h.inst, e.Ref)
	return nil
}

func (h *Host) Ready(ref string) (*Live, error) {
	leave, err := h.enter()
	if nil != err {
		return nil, err
	}
	defer leave()
	return h.ready(ref)
}

func (h *Host) ready(ref string) (*Live, error) {
	r, err := CanonRef(ref)
	if nil != err {
		return nil, err
	}
	if _, has := h.inst[r]; !has {
		if _, err := h.declare(r, DeclareSpec{}); nil != err {
			return nil, err
		}
	}
	if StatusDeclared == h.inst[r].Status {
		if _, err := h.load(r, DeclareSpec{}); nil != err {
			return nil, err
		}
	}
	return h.activate(r)
}

func (h *Host) unwind(e *Live) []string {
	e.selected = map[string]string{}
	errors := []string{}
	for i := len(e.scope) - 1; 0 <= i; i-- {
		errors = append(errors, callrelease(e.scope[i])...)
	}
	e.scope = []func(){}
	return errors
}

func callrelease(fn func()) (out []string) {
	defer func() {
		if r := recover(); nil != r {
			out = []string{fmt.Sprint(r)}
		}
	}()
	fn()
	return nil
}

// releasecheck is §8.3: "A failed release ends the instance in `failed`,
// exactly as a failed callback does (§5.2) — a release that raised may
// have leaked, and an instance that may be holding resources it cannot
// account for must not be reactivated."
func (h *Host) releasecheck(e *Live, errors []string) error {
	if 0 == len(errors) {
		return nil
	}
	e.Status = StatusFailed
	return Fail("plugin_release_failed",
		"release failed for "+e.Ref+": "+join(errors, "; "),
		map[string]any{"ref": e.Ref, "cause": errors})
}

func (h *Host) unmetof(e *Live) []string {
	out := []string{}
	for _, r := range Requirements(e.Options) {
		if !GatesActivation(r) {
			continue
		}
		if 0 == len(h.providersof(r)) {
			out = append(out, r.Name)
		}
	}
	return out
}

func (h *Host) chosen(e *Live, req Required, remember bool) string {
	cands := h.providersof(req)
	if 0 == len(cands) {
		return ""
	}
	if held, has := e.selected[req.Name]; has {
		for _, c := range cands {
			if c.Ref == held {
				return held
			}
		}
	}
	if remember {
		e.selected[req.Name] = cands[0].Ref
	}
	return cands[0].Ref
}

func (h *Host) boundproviders(e *Live) []string {
	out := []string{}
	for _, r := range Requirements(e.Options) {
		if !RestartsOnLoss(r) {
			continue
		}
		if ref := h.chosen(e, r, false); "" != ref && !hasstring(out, ref) {
			out = append(out, ref)
		}
	}
	return out
}

// consumersof: live instances whose selected provider is `ref` and which
// would be restarted by losing it.
func (h *Host) consumersof(ref string) []string {
	out := []string{}
	for _, r := range sortedkeys(h.inst) {
		c := h.inst[r]
		if r != ref && StatusLive == c.Status && hasstring(h.boundproviders(c), ref) {
			out = append(out, r)
		}
	}
	return out
}

func (h *Host) holdersof(ref string) []string {
	out := []string{}
	for _, r := range sortedkeys(h.inst) {
		c := h.inst[r]
		if r == ref || StatusLive != c.Status {
			continue
		}
		for _, req := range Requirements(c.Options) {
			if !GatesActivation(req) {
				continue
			}
			if h.chosen(c, req, false) == ref {
				out = append(out, r)
				break
			}
		}
	}
	return out
}

func (h *Host) providersof(req Required) []Candidate {
	cands := []Candidate{}
	want := canon(req.Name)
	for _, ref := range sortedkeys(h.inst) {
		t := h.inst[ref]
		if StatusLive != t.Status {
			continue
		}
		// A ref satisfies directly.
		if ref == want {
			cands = append(cands, Candidate{Ref: ref, Pos: t.Pos, Provides: Provided{Name: req.Name}})
			continue
		}
		for _, p := range t.provides {
			if p.Name == req.Name {
				cands = append(cands, Candidate{Ref: ref, Pos: t.Pos, Provides: p})
			}
		}
	}
	return ResolveCapability(req, cands)
}

func (h *Host) cascade(provider *Live, seen map[string]bool) {
	if seen[provider.Ref] {
		return
	}
	seen[provider.Ref] = true

	for _, r := range h.consumersof(provider.Ref) {
		c := h.inst[r]
		if StatusLive != c.Status {
			continue
		}
		h.cascade(c, seen) // deepest-first
		bad := nil != h.run(c, c.def.Deactivate, "deactivate")
		errors := h.unwind(c)
		if bad || 0 < len(errors) {
			// §5.2: ANY failure during a transition lands the instance in
			// `failed`. Marking it `pending` handed it straight back to
			// `reconcile`, which would activate it again the moment the
			// provider returned.
			c.Status = StatusFailed
			continue
		}
		c.Status = StatusPending
		c.unmet = h.unmetof(c)
	}
}

func (h *Host) held(e *Live) error {
	if "hold" != h.dependency {
		return nil
	}
	if h.coordinated {
		return nil
	}
	holders := h.holdersof(e.Ref)
	if 0 == len(holders) {
		return nil
	}
	return Fail("plugin_dependency_held",
		"instance is required by live consumers: "+e.Ref,
		map[string]any{"ref": e.Ref, "holders": holders})
}

func (h *Host) reconcile() {
	rounds := 0
	for moved := true; moved; {
		moved = false
		rounds++
		if 1000 < rounds {
			break
		}

		// Losses first, so a cascade settles in one pass rather than
		// alternating with re-activations.
		for _, r := range sortedkeys(h.inst) {
			e := h.inst[r]
			if StatusLive != e.Status {
				continue
			}
			lost := []Required{}
			for _, q := range Requirements(e.Options) {
				if GatesActivation(q) && 0 == len(h.providersof(q)) {
					lost = append(lost, q)
				}
			}
			if 0 == len(lost) {
				continue
			}
			restarts := false
			for _, q := range lost {
				if RestartsOnLoss(q) {
					restarts = true
				}
			}
			if !restarts {
				continue
			}
			bad := nil != h.run(e, e.def.Deactivate, "deactivate")
			errors := h.unwind(e)
			if bad || 0 < len(errors) {
				e.Status = StatusFailed
				moved = true
				continue
			}
			e.Status = StatusPending
			e.unmet = h.unmetof(e)
			moved = true
		}

		for _, r := range sortedkeys(h.inst) {
			e := h.inst[r]
			if StatusPending != e.Status {
				continue
			}
			if 0 < len(h.unmetof(e)) {
				continue
			}
			if err := h.run(e, e.def.Activate, "activate"); nil != err {
				h.unwind(e)
				e.Status = StatusFailed
				moved = true
				continue
			}
			e.Status = StatusLive
			e.unmet = []string{}
			moved = true
		}
	}
}

// --- ordering --------------------------------------------------------

func (h *Host) Order(point string) ([]string, error) {
	refs := sortedkeys(h.inst)
	sort.SliceStable(refs, func(i, j int) bool {
		return h.inst[refs[i]].Seq < h.inst[refs[j]].Seq
	})
	bindings := []Binding{}
	for _, r := range refs {
		if StatusLive != h.inst[r].Status {
			continue
		}
		bindings = append(bindings, Binding{Ref: r, Pos: h.inst[r].Pos, Order: h.inst[r].order})
	}
	var pin Pin
	if "" != point {
		if spec, ok := h.points[point]; ok {
			pin = spec.Pin
		}
	}
	return ResolveOrder(bindings, pin)
}

// --- points ----------------------------------------------------------

// bound returns the live bindings on a point, in resolved order.
// Recomputed on any change to the live set (§7) rather than cached at
// startup — the bug a host discovers only when something deactivates in
// production.
func (h *Host) bound(point string) ([]Bound, error) {
	ranked, err := h.Order(point)
	if nil != err {
		return nil, err
	}
	out := []Bound{}
	for _, ref := range ranked {
		e := h.inst[ref]
		// The band is the INSTANCE's ordering block (§7), stamped by the
		// host. A plugin passing its own would be ranking itself above
		// the order its document declared.
		band := 0
		if nil != e.order && nil != e.order.Band {
			band = *e.order.Band
		}
		for _, b := range e.bindings {
			if b.Point == point {
				stamped := b
				stamped.Band = band
				out = append(out, stamped)
			}
		}
	}
	return out, nil
}

func (h *Host) pointspec(point string, want Kind) (Spec, error) {
	spec, ok := h.points[point]
	if !ok {
		return Spec{}, Fail("plugin_point_unknown", "no such point: "+point,
			map[string]any{"point": point})
	}
	if KindHook == want {
		// A point with no declared kind is a hook, which is what makes
		// `{}` the minimal point declaration.
		if "" != spec.Kind && KindHook != spec.Kind {
			return Spec{}, Fail("plugin_point_kind", "point is not a hook: "+point,
				map[string]any{"point": point, "kind": string(spec.Kind)})
		}
		return spec, nil
	}
	if spec.Kind != want {
		return Spec{}, Fail("plugin_point_kind", "point is not a "+string(want)+": "+point,
			map[string]any{"point": point, "kind": string(spec.Kind)})
	}
	return spec, nil
}

func (h *Host) Emit(point string, arg any) (any, error) {
	spec, err := h.pointspec(point, KindHook)
	if nil != err {
		return nil, err
	}
	bindings, err := h.bound(point)
	if nil != err {
		return nil, err
	}
	mode := spec.Mode
	if "" == mode {
		mode = ModeEmit
	}
	return Emit(bindings, mode, arg)
}

func (h *Host) Call(point string, args ...any) (any, error) {
	spec, err := h.pointspec(point, KindChain)
	if nil != err {
		return nil, err
	}
	bindings, err := h.bound(point)
	if nil != err {
		return nil, err
	}
	base := spec.Base
	if nil == base {
		base = func(a ...any) any {
			if 0 == len(a) {
				return nil
			}
			return a[0]
		}
	}
	return Compose(bindings, base)(args...), nil
}

func (h *Host) Provide(point string, args ...any) (any, error) {
	spec, err := h.pointspec(point, KindProvider)
	if nil != err {
		return nil, err
	}
	bindings, err := h.bound(point)
	if nil != err {
		return nil, err
	}
	pick, err := Provider(bindings, spec)
	if nil != err {
		return nil, err
	}
	if nil == pick.Winner {
		return spec.Default, nil
	}
	return pick.Winner.Fn(args...), nil
}

// Shadowed makes the losers VISIBLE rather than silently ignored (§6.3).
func (h *Host) Shadowed(point string) ([]string, error) {
	spec, ok := h.points[point]
	if !ok {
		return []string{}, nil
	}
	bindings, err := h.bound(point)
	if nil != err {
		return nil, err
	}
	pick, err := Provider(bindings, spec)
	if nil != err {
		return nil, err
	}
	return pick.Shadowed, nil
}

func (h *Host) Exports(spec string) (any, error) {
	all := []Exported{}
	for _, ref := range sortedkeys(h.inst) {
		e := h.inst[ref]
		// Exports of a `loaded` (not live) instance are VISIBLE (§11).
		if StatusDeclared == e.Status || StatusFailed == e.Status {
			continue
		}
		for _, k := range sortedkeys(e.exports) {
			all = append(all, Exported{Ref: ref, Key: k, Value: e.exports[k]})
		}
	}
	return ResolveExport(spec, all)
}

// Capability lists the live providers of a capability, best-first
// (§11.1).
func (h *Host) Capability(name string) []string {
	cands := []Candidate{}
	for _, ref := range sortedkeys(h.inst) {
		e := h.inst[ref]
		if StatusLive != e.Status {
			continue
		}
		for _, p := range e.provides {
			if p.Name == name {
				cands = append(cands, Candidate{Ref: ref, Pos: e.Pos, Provides: p})
			}
		}
	}
	out := []string{}
	for _, c := range ResolveCapability(Required{Name: name}, cands) {
		out = append(out, c.Ref)
	}
	return out
}

// --- documents -------------------------------------------------------

func (h *Host) Apply(doc any, profile string) error {
	leave, err := h.enter()
	if nil != err {
		return err
	}
	defer leave()
	return h.apply(doc, profile)
}

func (h *Host) apply(doc any, profile string) error {
	profile = or(profile, h.opts.Profile)
	norm, err := NormalizeConfig(NormalizeInput{
		Doc: doc, Profile: profile, Keys: h.opts.Keys, Reserved: h.reserved,
	})
	if nil != err {
		return err
	}

	want := norm.Order
	optionsof := map[string]map[string]any{}
	for _, ref := range want {
		options, err := ResolveOptions(ResolveInput{
			Ref: ref, Doc: doc, Profile: profile,
			Shape: h.shapeof(ref), HostDefaults: h.opts.Defaults[refname(ref)],
		})
		if nil != err {
			return err
		}
		optionsof[ref] = options
	}

	// wantlive: should this ref be LIVE after the apply? False for a ref
	// the document declares lazy or inactive AND for one it does not
	// name at all — which is what makes "unload what is gone" and
	// "unload what was toggled off" one rule rather than two.
	wantlive := func(ref string) bool {
		ent, has := norm.Instance[ref]
		return has && ent.Active && "eager" == ent.Start
	}

	// --- phase 1: deactivations and unloads, in REVERSE load order ---
	drop := []string{}
	for _, ref := range sortedkeys(h.inst) {
		if StatusDeclared == h.inst[ref].Status {
			continue
		}
		if !wantlive(ref) {
			drop = append(drop, ref)
		}
	}
	// Highest `pos` first, ref-descending for a tie, so a consumer
	// declared after its provider goes down first.
	sort.SliceStable(drop, func(i, j int) bool {
		a, b := h.inst[drop[i]], h.inst[drop[j]]
		if a.Pos != b.Pos {
			return a.Pos > b.Pos
		}
		return drop[i] > drop[j]
	})
	for _, ref := range drop {
		if err := h.unload(ref); nil != err {
			return err
		}
	}

	// --- phase 2: declare and patch EVERYTHING, in load order --------
	for _, ref := range want {
		ent := norm.Instance[ref]
		pos := ent.Pos
		if _, err := h.declare(ref, DeclareSpec{
			Order: ent.Order, Pos: &pos}); nil != err {
			return err
		}
		// The bar is REASSERTED ON EVERY APPLY, in both directions — a
		// document that turns the instance back on clears it, which is
		// the whole point of a config switch.
		h.inst[ref].barred = !ent.Active
		// REFILL rather than REBIND. A definition's callbacks close over
		// the options map they were handed at `define`; replacing the
		// reference here would leave every binding reading the values the
		// first apply gave it.
		refill(h.inst[ref].Options, optionsof[ref])
		h.inst[ref].order = ent.Order
		h.inst[ref].Pos = ent.Pos
	}

	for _, ref := range want {
		if wantlive(ref) {
			if _, err := h.load(ref, DeclareSpec{}); nil != err {
				return err
			}
		}
	}

	// --- phase 4: activations, in load order -------------------------
	for _, ref := range want {
		if wantlive(ref) {
			if _, err := h.activate(ref); nil != err {
				return err
			}
		}
	}
	return nil
}

func (h *Host) shapeof(ref string) any {
	def, ok := h.catalog.Get(refname(ref))
	if !ok {
		return nil
	}
	return def.Shape
}

func (h *Host) SetOptions(ref string, patch map[string]any) error {
	leave, err := h.enter()
	if nil != err {
		return err
	}
	defer leave()
	return h.setoptions(ref, patch)
}

func (h *Host) setoptions(ref string, patch map[string]any) error {
	e, err := h.need(ref)
	if nil != err {
		return err
	}
	previous := map[string]any{}
	for k, v := range e.Options {
		previous[k] = v
	}
	resolved, err := ResolveOptions(ResolveInput{
		Ref: e.Ref, Shape: h.shapeof(e.Ref), Doc: map[string]any{},
		Patch: shallowmerge(previous, patch)})
	if nil != err {
		return err
	}
	refill(e.Options, resolved)
	if StatusLive == e.Status {
		if nil != e.def.Reconfigure {
			h.intransition = true
			err := e.def.Reconfigure(h.api(e), e.Options, previous)
			h.intransition = false
			return err
		}
		// Always correct and sometimes expensive; `reconfigure` exists
		// to make the common case cheap (§9.4).
		if _, err := h.deactivate(e.Ref); nil != err {
			return err
		}
		if _, err := h.activate(e.Ref); nil != err {
			return err
		}
	}
	return nil
}

func refill(target map[string]any, source map[string]any) {
	for k := range target {
		delete(target, k)
	}
	for k, v := range source {
		target[k] = v
	}
}

func shallowmerge(a map[string]any, b map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

func (h *Host) Close() error {
	leave, err := h.enter()
	if nil != err {
		return err
	}
	defer leave()
	return h.closeall()
}

func (h *Host) closeall() error {
	h.coordinated = true
	defer func() { h.coordinated = false }()
	refs := sortedkeys(h.inst)
	for i := len(refs) - 1; 0 <= i; i-- {
		if err := h.unload(refs[i]); nil != err {
			return err
		}
	}
	return nil
}

func (h *Host) PositionOf(ref string, point string) (Position, error) {
	e := h.inst[canon(ref)]
	if nil == e {
		return Position{}, Fail("plugin_not_loaded", "no such instance: "+ref,
			map[string]any{"ref": ref})
	}
	ranked, err := h.Order(point)
	if nil != err {
		return Position{}, err
	}
	index := indexof(ranked, e.Ref)
	return Position{
		Index: index, Count: len(ranked),
		Outermost: 0 == index,
		Innermost: index == len(ranked)-1,
	}, nil
}

// Define adds a definition to this host's catalog.
func (h *Host) Define(def Definition) error { return h.catalog.Add(def) }
