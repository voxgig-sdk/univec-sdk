// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/config.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The declarative document (§9): normalization, and the ten-level
 * precedence ladder.
 *
 * TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
 *
 * NormalizeConfig normalizes STRUCTURE and ENTRY KEYS. It does not
 * merge options, and cannot: §9.4 makes merge behaviour a property of
 * the definition's option SHAPE, which normalization has never seen. A
 * normalizer that flattened the option layers would make
 * `$MERGE: append` unimplementable at load time, because the layers it
 * must concatenate would already be collapsed.
 *
 * ResolveOptions applies the ladder, and it is the only place that
 * knows the shape. */

package plugin

import "sort"

// ---------------------------------------------------------------------
// NormalizeConfig
// ---------------------------------------------------------------------

type Keys struct {
	Instance string `json:"instance,omitempty"`
	Default  string `json:"default,omitempty"`
}

type NormalizeInput struct {
	Doc     any    `json:"doc"`
	Profile string `json:"profile,omitempty"`
	// Keys is §9.1: a host may rename `instance` and `default` into its
	// own vocabulary.
	Keys Keys `json:"keys,omitempty"`
	// Reserved is §9.1: refs the host declares itself and always wins on.
	Reserved []string `json:"reserved,omitempty"`
}

func NormalizeConfig(input NormalizeInput) (Normalized, error) {
	doc := asmap(input.Doc)
	ikey := or(input.Keys.Instance, "instance")
	dkey := or(input.Keys.Default, "default")
	reserved := input.Reserved

	// The rename is applied at TWO PLACES AND NO OTHERS: the document
	// root, and every profile.<name> overlay root (§9.1). A rename
	// applied only at the root would leave `profile.prod.sdk`
	// untranslated and silently drop every environment override the host
	// depends on. Recursing further would be worse: option data is the
	// definition's.
	baseinst := doc[ikey]
	basedef := asmap(doc[dkey])

	var overlay map[string]any
	if "" != input.Profile {
		overlay = asmap(asmap(doc["profile"])[input.Profile])
	}
	overinst := overlay[ikey]
	overdef := asmap(overlay[dkey])

	// Entry layers, base then overlay, each as {ref -> entry} plus the
	// order the form implies.
	base, err := entries(baseinst)
	if nil != err {
		return Normalized{}, err
	}
	over, err := entries(overinst)
	if nil != err {
		return Normalized{}, err
	}

	for _, group := range [][]string{
		sortedkeys(base.emap), sortedkeys(over.emap),
		sortedkeys(basedef), sortedkeys(overdef),
	} {
		for _, r := range group {
			if err := checkreservedref(r, reserved); nil != err {
				return Normalized{}, err
			}
		}
	}

	// A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the
	// hard way: deriving order from a partial array silently dropped
	// config-activated features. Refs in the base but absent from the
	// overlay still load, in sorted position AFTER the listed ones. A
	// profile may also INTRODUCE a ref the base never declared.
	order := []string{}
	for _, r := range over.order {
		if !hasstring(order, r) {
			order = append(order, r)
		}
	}
	// The remainder keeps the BASE's own order — array position for the
	// array form, sorted refs for the map form. Re-sorting here would
	// discard an array document's positional order entirely, which is
	// the one thing the array form exists to express.
	for _, r := range base.order {
		if !hasstring(order, r) {
			order = append(order, r)
		}
	}

	instance := map[string]*Instance{}
	for i, ref := range order {
		b := base.emap[ref]
		o := over.emap[ref]

		// MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE
		// RESULT (§9.3). A safety rule, not a tidiness one: if the
		// overlay had its defaults filled in before merging it would
		// carry a synthesized active:true and overwrite a base's false —
		// silently re-enabling a deliberately disabled integration in
		// production.
		active := asbool(pick(o, "active", pick(b, "active", true)), true)
		start := asstring(pick(o, "start", pick(b, "start", "eager")), "eager")
		ord := pick(o, "order", pick(b, "order", nil))

		// Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
		layers := []any{}
		nm := refname(ref)
		if v, ok := asmap(basedef[nm])["options"]; ok {
			layers = append(layers, v)
		}
		if v, ok := asmap(b)["options"]; ok {
			layers = append(layers, v)
		}
		if v, ok := asmap(overdef[nm])["options"]; ok {
			layers = append(layers, v)
		}
		if v, ok := asmap(o)["options"]; ok {
			layers = append(layers, v)
		}

		ent := &Instance{Pos: i, Active: active, Start: start, OptionLayers: layers}
		if nil != ord {
			ent.Order = orderblock(ord)
		}
		instance[ref] = ent
	}

	// `default` DECLARES NOTHING (§9.3). It is a base for every instance
	// of that definition; it does not create one, and an entry for a
	// name with no instances is inert rather than an error — which is
	// what makes a shared library of defaults shippable.
	defout := map[string]any{}
	for _, n := range sortedkeys(basedef) {
		defout[n] = basedef[n]
	}
	for _, n := range sortedkeys(overdef) {
		defout[n] = overdef[n]
	}

	return Normalized{Instance: instance, Order: order, Default: defout}, nil
}

type entryset struct {
	emap  map[string]any
	order []string
}

// entries reduces both document forms to {ref -> entry} plus the order
// the form implies: array POSITION for the array form, sorted refs for
// the map form.
func entries(src any) (entryset, error) {
	out := entryset{emap: map[string]any{}, order: []string{}}
	if nil == src {
		return out, nil
	}

	if list, ok := aslist(src); ok {
		for _, item := range list {
			raw, _ := asmap(item)["ref"]
			s, _ := raw.(string)
			ref, err := CanonRef(s)
			if nil != err {
				return out, err
			}
			out.emap[ref] = item
			out.order = append(out.order, ref)
		}
		return out, nil
	}

	// Map-form refs arrive as KEYS, through a different path than an
	// array element's `ref` field — and must canonicalize the same way.
	m := asmap(src)
	for _, key := range sortedkeys(m) {
		ref, err := CanonRef(key)
		if nil != err {
			return out, err
		}
		out.emap[ref] = m[key]
	}
	// Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase
	// refs sort identically under all three, so only mixed input
	// discriminates: '@' is 0x40, uppercase 0x41-0x5A, lowercase
	// 0x61-0x7A. Go's sort.Strings is exactly bytewise.
	out.order = sortedkeys(out.emap)
	sort.Strings(out.order)
	return out, nil
}

// checkreservedref is §9.1: reservation is all-or-nothing per NAME, so
// the tagged forms go too. A configuration surface that can disable the
// thing reading it is not a surface, it is a trap.
func checkreservedref(ref string, reserved []string) error {
	if 0 == len(reserved) {
		return nil
	}
	if hasstring(reserved, refname(ref)) {
		return Fail("plugin_ref_reserved", "ref is reserved by the host: "+ref,
			map[string]any{"ref": ref})
	}
	return nil
}

// ---------------------------------------------------------------------
// ResolveOptions — §9.3's ten levels, and §9.4's merge directives
// ---------------------------------------------------------------------

type ResolveInput struct {
	Ref string `json:"ref"`
	// Shape is level 1 — the definition's option shape. Also carries the
	// $MERGE directives, which is why merging cannot happen without it.
	Shape        any    `json:"shape,omitempty"`
	HostDefaults any    `json:"hostdefaults,omitempty"` // 2
	Doc          any    `json:"doc,omitempty"`          // 3-6
	Profile      string `json:"profile,omitempty"`
	Env          any    `json:"env,omitempty"`         // 7
	HostOptions  any    `json:"hostoptions,omitempty"` // 8
	LoadOptions  any    `json:"loadoptions,omitempty"` // 9
	Patch        any    `json:"patch,omitempty"`       // 10
}

func ResolveOptions(input ResolveInput) (map[string]any, error) {
	shape := asmap(input.Shape)
	if err := CheckShape(shape); nil != err {
		return nil, err
	}

	ref, err := CanonRef(input.Ref)
	if nil != err {
		return nil, err
	}
	name := refname(ref)
	doc := asmap(input.Doc)

	var overlay map[string]any
	if "" != input.Profile {
		overlay = asmap(asmap(doc["profile"])[input.Profile])
	}

	// ONE ordered merge, lowest to highest. Levels 3-6 are not two
	// namespaces collapsed separately and composed afterwards: that
	// inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
	// SPECIFICITY, so a prod per-definition default would lose to a base
	// instance value.
	lo3, err := optsof(doc["default"], name)
	if nil != err {
		return nil, err
	}
	lo4, err := optsof(doc["instance"], ref)
	if nil != err {
		return nil, err
	}
	lo5, err := optsof(overlay["default"], name)
	if nil != err {
		return nil, err
	}
	lo6, err := optsof(overlay["instance"], ref)
	if nil != err {
		return nil, err
	}

	layers := []any{
		defaultsof(shape),  // 1
		input.HostDefaults, // 2
		lo3, lo4, lo5, lo6, // 3-6
		input.Env,         // 7
		input.HostOptions, // 8
		input.LoadOptions, // 9
		input.Patch,       // 10
	}

	var out any = map[string]any{}
	for _, layer := range layers {
		if nil == layer {
			continue
		}
		out = mergeone(out, layer, shape)
	}
	return asmap(out), nil
}

// defaultsof: the shape's non-directive values are the level-1 defaults.
func defaultsof(shape map[string]any) map[string]any {
	out := map[string]any{}
	for _, k := range sortedkeys(shape) {
		v := shape[k]
		if m, ok := v.(map[string]any); ok {
			if _, has := m["$MERGE"]; has {
				continue
			}
		}
		out[k] = v
	}
	return out
}

func optsof(src any, key string) (any, error) {
	if nil == src {
		return nil, nil
	}
	// The array form is equivalent to the map form (§9.1).
	if list, ok := aslist(src); ok {
		for _, item := range list {
			raw, _ := asmap(item)["ref"]
			s, _ := raw.(string)
			c, err := CanonRef(s)
			if nil != err {
				return nil, err
			}
			if c == key {
				v, has := asmap(item)["options"]
				if !has {
					return nil, nil
				}
				return v, nil
			}
		}
		return nil, nil
	}
	m := asmap(src)
	for _, k := range sortedkeys(m) {
		c, err := CanonRef(k)
		if nil != err {
			return nil, err
		}
		if c == key {
			v, has := asmap(m[k])["options"]
			if !has {
				return nil, nil
			}
			return v, nil
		}
	}
	return nil, nil
}

// mergeone merges ONE layer onto the accumulator, honouring the shape's
// directives. The directive holds at EVERY precedence level, not only
// between document levels — §9.4 makes it a property of the shape, which
// does not know which layer a value arrived from.
func mergeone(base any, over any, shape map[string]any) any {
	if nil == over {
		return base
	}
	if !ismap(base) || !ismap(over) {
		return clonevalue(over)
	}

	bm := asmap(base)
	om := asmap(over)
	out := map[string]any{}
	for k, v := range bm {
		out[k] = v
	}

	for _, k := range sortedkeys(om) {
		var directive any
		if nil != shape {
			directive = asmap(shape[k])["$MERGE"]
		}
		b := out[k]
		o := om[k]

		if "replace" == directive {
			out[k] = clonevalue(o)
		} else if "append" == directive {
			bl, ok := aslist(b)
			if !ok {
				bl = []any{}
			}
			ol, ok := aslist(o)
			if !ok {
				ol = []any{o}
			}
			joined := make([]any, 0, len(bl)+len(ol))
			joined = append(joined, bl...)
			joined = append(joined, ol...)
			out[k] = joined
		} else if n, deep := deepof(directive); deep {
			out[k] = deepto(b, o, n)
		} else {
			// Library default: deep for maps, REPLACE for lists.
			// struct.merge is element-wise by index, which for option
			// maps is nearly always wrong — ["a"] over ["x","y","z"]
			// yielding ["a","y","z"] is the defect station hit on
			// secrets.providers.
			if ismap(b) && ismap(o) {
				out[k] = mergeone(b, o, nil)
			} else {
				out[k] = clonevalue(o)
			}
		}
	}
	return out
}

// deepto merges N levels below this key, replacing below that.
func deepto(base any, over any, n int) any {
	if 0 >= n {
		return clonevalue(over)
	}
	if !ismap(base) || !ismap(over) {
		return clonevalue(over)
	}
	bm, om := asmap(base), asmap(over)
	out := map[string]any{}
	for k, v := range bm {
		out[k] = v
	}
	for _, k := range sortedkeys(om) {
		out[k] = deepto(out[k], om[k], n-1)
	}
	return out
}

// §9.4: N is an integer of at least 1, and everything else is an error.
//
// `{"deep": 0}` is rejected DESPITE having an obvious reading, because
// "replace at this key" already has a spelling and two spellings for one
// behaviour is the defect class this repo exists to avoid. Without the
// stated domain each port picks its own reading — reject, replace,
// unlimited merge, or clamp to 1 — and the same document resolves
// differently per language.
var mergeWords = []string{"replace", "append"}

func CheckShape(shape any) error {
	m, ok := shape.(map[string]any)
	if !ok {
		return nil
	}
	for _, k := range sortedkeys(m) {
		v, ok := m[k].(map[string]any)
		if !ok {
			continue
		}
		d, has := v["$MERGE"]
		if !has {
			continue
		}

		if s, ok := d.(string); ok {
			if !hasstring(mergeWords, s) {
				return Fail("plugin_shape_invalid",
					"invalid $MERGE directive at "+k+": "+s,
					map[string]any{"key": k, "directive": d})
			}
			continue
		}
		if dm, ok := d.(map[string]any); ok {
			if n, has := dm["deep"]; has {
				if !isposint(n) {
					return Fail("plugin_shape_invalid",
						"invalid $MERGE deep at "+k+": "+compactjson(n),
						map[string]any{"key": k, "directive": d})
				}
				continue
			}
		}
		return Fail("plugin_shape_invalid",
			"invalid $MERGE directive at "+k+": "+compactjson(d),
			map[string]any{"key": k, "directive": d})
	}
	return nil
}

// deepof reads `{"deep": N}` off a directive, after CheckShape has
// already established the domain.
func deepof(directive any) (int, bool) {
	dm, ok := directive.(map[string]any)
	if !ok {
		return 0, false
	}
	n, has := dm["deep"]
	if !has {
		return 0, false
	}
	f, ok := tonumber(n)
	if !ok {
		return 0, false
	}
	return int(f), true
}

// ---------------------------------------------------------------------
// The JSON-value readers. The canonical gets these from JavaScript's
// coercion rules; a typed port needs them written down, which is a
// large part of why go is P4's first port.
// ---------------------------------------------------------------------

func asmap(v any) map[string]any {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return map[string]any{}
}

// pick is the canonical's `pick(src, key, dflt)`: PRESENCE decides, not
// truthiness and not nil. A JSON `null` is a present value in
// JavaScript (`undefined !== null`), so it must be one here.
func pick(src any, key string, dflt any) any {
	m, ok := src.(map[string]any)
	if !ok {
		return dflt
	}
	if v, has := m[key]; has {
		return v
	}
	return dflt
}

func asbool(v any, dflt bool) bool {
	if b, ok := v.(bool); ok {
		return b
	}
	return dflt
}

func asstring(v any, dflt string) string {
	if s, ok := v.(string); ok {
		return s
	}
	return dflt
}

func or(v string, dflt string) string {
	if "" == v {
		return dflt
	}
	return v
}

// tonumber accepts every numeric shape a decoded document can carry:
// encoding/json gives float64, a hand-built map may carry int.
func tonumber(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case float32:
		return float64(n), true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	}
	return 0, false
}

func isposint(v any) bool {
	f, ok := tonumber(v)
	if !ok {
		return false
	}
	return f == float64(int(f)) && 1 <= f
}

// asorderref reads ONE spelling or a LIST of them into an OrderRef, and
// KEEPS THE AUTHORED VALUE so normalization can hand it back untouched.
//
// It used to be a bare asstring(), so a list decoded to "" and the
// constraint was SILENTLY DROPPED - the sort ran as if nothing had been
// declared.
//
// `stated` is separate from the value because an ABSENT key and a key
// authored as `null` are different documents, and a map index alone
// cannot tell them apart.
//
// The other four ports have no type like this at all: they carry the
// authored block straight through (`ent.order = ord`), so every spelling
// survives normalization by construction. Go is the only port that
// decodes and rebuilds, and a rebuild loses whatever it does not model -
// first the list form, then scalar-vs-one-element-list, then an authored
// empty list, then an authored null. One cause, four parity breaks, none
// of which the corpus could see until `config/normorder` was written.
// Keeping the authored value ends the class rather than the instance.
func asorderref(v any, stated bool) OrderRef {
	if !stated {
		return OrderRef{}
	}

	out := OrderRef{raw: v, set: true, list: []string{}}

	// Slices are COPIED into `raw`. A caller that keeps its own handle on
	// the slice it passed in must not be able to change what this ref
	// marshals afterwards, while the parsed form stays as it was.
	switch list := v.(type) {
	case string:
		if "" != list {
			out.list = append(out.list, list)
		}
	case []string:
		out.raw = append([]string{}, list...)
		for _, one := range list {
			if "" != one {
				out.list = append(out.list, one)
			}
		}
	case []any:
		out.raw = append([]any{}, list...)
		for _, item := range list {
			if one, ok := item.(string); ok && "" != one {
				out.list = append(out.list, one)
			}
		}
	}

	// Anything else - a number, a map, a null - names no binding, so it
	// constrains nothing. It was still STATED, and goes back verbatim.

	return out
}

// orderblock decodes an `order` entry off a document. The canonical
// stores the raw value and reads `.before`, `.after`, `.band` off it
// wherever it lands; a typed port decodes once, here.
func orderblock(v any) *OrderBlock {
	m, ok := v.(map[string]any)
	if !ok {
		return nil
	}

	out := &OrderBlock{}

	before, statedbefore := m["before"]
	after, statedafter := m["after"]

	out.Before = asorderref(before, statedbefore)
	out.After = asorderref(after, statedafter)

	if f, ok := tonumber(m["band"]); ok {
		n := int(f)
		out.Band = &n
	}

	return out
}
