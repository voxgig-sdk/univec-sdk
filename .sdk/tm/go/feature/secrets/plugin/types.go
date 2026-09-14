// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/types.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Shared types. Deliberately small: the design's §19 budget says the
 * library owns naming, configuration, lifecycle, ordering, binding and
 * teardown, and nothing else.
 *
 * GO IS THE FIRST PORT AND IT CHANGES ONE THING ON PURPOSE (§18, P4):
 * errors are RETURNED, not raised. The canonical raises, and every
 * signature that could fail here returns `error` instead. That is the
 * point of porting Go first — "static-only + typed extension points +
 * explicit errors will find every TypeScript-shaped assumption in the
 * model" — and the corpus compares by CODE, which survives the change
 * intact. */

package plugin

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// Ref is the two halves of an identity (§4). Tag is "" when absent —
// never nil and never missing, because a port returning three shapes
// for two states makes every downstream comparison a special case.
type Ref struct {
	Name string `json:"name"`
	Tag  string `json:"tag"`
}

// Status is one of §5.1's seven statuses, and no more. A port that adds
// an eighth is diverging. `loading` and `closing` are observable only
// from inside a callback or from another thread.
type Status string

const (
	StatusDeclared Status = "declared"
	StatusLoaded   Status = "loaded"
	StatusPending  Status = "pending"
	StatusLive     Status = "live"
	StatusFailed   Status = "failed"
	StatusLoading  Status = "loading"
	StatusClosing  Status = "closing"
)

// OrderBlock is §4.4 of DOCS.md — `band` rather than a nested `order`,
// because `order.order` needs explaining every time it is read.
type OrderBlock struct {
	Before OrderRef `json:"before,omitempty"`
	After  OrderRef `json:"after,omitempty"`
	Band   *int     `json:"band,omitempty"`
}

// MarshalJSON omits an unstated constraint entirely.
//
// `omitempty` does not apply to a struct, so without this an absent
// `before` serialized as `"before": null` while canonical simply has no
// key - the same language-dependent shape divergence as emitting a list
// for an authored scalar, one level up.
func (block OrderBlock) MarshalJSON() ([]byte, error) {
	out := map[string]any{}
	if block.Before.Stated() {
		out["before"] = block.Before
	}
	if block.After.Stated() {
		out["after"] = block.After
	}
	if nil != block.Band {
		out["band"] = *block.Band
	}

	// `marshal` for the same reason as OrderRef.MarshalJSON above.
	return marshal(out)
}

// OrderRef is ONE spelling or a LIST of them.
//
// plugin used to type this as a bare string, so a list matched nothing and
// was SILENTLY DROPPED - the sort came out as if no constraint had been
// declared. Go could not even represent the input.
//
// `raw` is THE AUTHORED VALUE, kept so normalization can hand the block
// back exactly as written; `List` is the parsed form the sort consumes,
// and `set` says whether the key was stated at all. Canonical does not
// need any of this: it never decodes the block, it assigns it (`ent.order
// = ord`), so every spelling survives untouched. Go is the only port that
// decodes and rebuilds, and a rebuild silently loses whatever it does not
// model. That single cause produced four separate parity breaks - the
// list form, scalar-vs-one-element-list, an authored empty list, an
// authored null - and the corpus could see none of them until
// `config/normorder` was written to assert the block's own shape.
//
// `set` is deliberately not `0 < len(list)`: an authored `[]` states a
// constraint that names nothing, which is NOT the same document as an
// absent key.
//
// `raw` is the ONE source of truth and `list` is a derived cache, both
// unexported. An earlier round exported `List`, which made the value
// mutable from outside and gave it two sources that could disagree: a
// caller mutating the slice it passed in changed what marshalled while
// ResolveOrder kept the old constraint, and editing `List` directly did
// the reverse. A persisted-then-reloaded config could then order
// differently from the live one. NewOrderRef is now the only way to build
// one, it copies what it is given, and Refs() hands back a copy.
type OrderRef struct {
	raw  any
	list []string
	set  bool
}

// Refs is the parsed spellings this ref names, as a copy. Callers get no
// handle on the ref's own state.
func (ref OrderRef) Refs() []string {
	out := make([]string, len(ref.list))
	copy(out, ref.list)

	return out
}

// UnmarshalJSON decodes to `any` first and then goes through the SAME
// decoder the in-memory path uses.
//
// It used to try `string` and then `[]string` directly. That is wrong
// twice over: json.Unmarshal into a string is a documented NO-OP on JSON
// null and returns a nil error, so `{"after":null}` took the string
// branch and came back as `{"after":""}` - an empty-string constraint
// nobody wrote; and having two decoders for one rule let them drift, so
// this path hard-failed on values the in-memory path quietly accepted.
func (ref *OrderRef) UnmarshalJSON(data []byte) error {
	var authored any

	if err := json.Unmarshal(data, &authored); nil != err {
		return err
	}

	*ref = asorderref(authored, true)

	return nil
}

// Stated reports whether this ref says anything at all - because a
// document stated it, or because a Go caller built it by hand.
//
// It is NOT `0 < len(List)`: an authored `[]` states a constraint that
// names nothing, and an absent key states nothing, and those are
// different documents.
func (ref OrderRef) Stated() bool {
	return ref.set
}

// MarshalJSON replays the AUTHORED value.
//
// A ref that was never stated marshals as `null`, and OrderBlock omits
// the key rather than emitting that. There is no `List` fallback and no
// way to build a ref outside NewOrderRef: an earlier round had both, and
// carrying two ways to construct one value is exactly what let them
// desync.
//
// `marshal`, not `json.Marshal`. The latter escapes `<`, `>` and `&` as
// \u00XX, which canonical's JSON.stringify does not, and an outer encoder
// cannot undo an escape its input already carries - so a spelling holding
// any of those three came back with different bytes from every other
// port. go/AGENTS.md states this rule outright and both marshallers here
// broke it.
func (ref OrderRef) MarshalJSON() ([]byte, error) {
	if ref.set {
		return marshal(ref.raw)
	}

	return []byte("null"), nil
}

// NewOrderRef builds an OrderRef from Go, for callers assembling a
// document programmatically rather than decoding one. It takes what a
// document may hold - a string, a []string, a []any of strings, or nil -
// and runs it through the SAME decoder the JSON and in-memory paths use,
// so a constructed ref and a decoded one cannot disagree.
func NewOrderRef(spelling any) OrderRef {
	return asorderref(spelling, true)
}

// Instance is a normalized instance entry. Option data is NOT merged
// here — see OptionLayers.
type Instance struct {
	Pos    int         `json:"pos"`
	Active bool        `json:"active"`
	Start  string      `json:"start"`
	Order  *OrderBlock `json:"order,omitempty"`
	// OptionLayers holds levels 3-6 that are present, IN LADDER ORDER
	// (§9.3).
	//
	// Normalization does not merge these, and cannot: §9.4 makes merge
	// behaviour a property of the definition's option shape, which
	// normalization has never seen. Flattening them here would make
	// `$MERGE: append` unimplementable at load time, because the layers
	// it must concatenate would already be collapsed.
	OptionLayers []any `json:"optionlayers"`
}

type Normalized struct {
	Instance map[string]*Instance `json:"instance"`
	Order    []string             `json:"order"`
	Default  map[string]any       `json:"default"`
}

// DetailOrder is §12's detail fields, IN THIS FIXED ORDER.
//
// The order is part of the contract, not a formatting preference. An
// earlier draft named six fields while other sections promised
// diagnostics that had nowhere to go, which would have left each port
// inventing its own order and breaking message parity.
var DetailOrder = []string{
	"host", "ref", "name", "tag", "point", "key", "capability",
	"range", "version", "match", "candidates", "cycle", "holders",
	"refs", "path", "cause",
}

// compactjson renders a value the way JSON.stringify does: compact, and
// WITHOUT Go's default HTML escaping, which would turn `<` into `<`
// and break message parity against every other port.
func compactjson(v any) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); nil != err {
		return fmt.Sprintf("%v", v)
	}
	return string(bytes.TrimRight(buf.Bytes(), "\n"))
}

// FormatError renders `plugin/<code>: <text> [<key>=<value> …]`.
//
// Values render as COMPACT JSON, so a value containing a space or a
// bracket cannot break the parse, and a list renders as a JSON array.
// The bracket is absent entirely when no field applies.
func FormatError(code string, text string, details map[string]any) string {
	parts := []string{}
	for _, k := range DetailOrder {
		v, ok := details[k]
		if !ok {
			continue
		}
		parts = append(parts, k+"="+compactjson(v))
	}
	tail := ""
	if 0 < len(parts) {
		tail = " ["
		for i, p := range parts {
			if 0 < i {
				tail += " "
			}
			tail += p
		}
		tail += "]"
	}
	return "plugin/" + code + ": " + text + tail
}

// PluginError carries a §12 code. Ports compare by CODE and never by
// message: wording is a port's own business, and pinning the words would
// make every translation a corpus change. The FORMAT, however, is
// pinned — a parseable message is what makes a log searchable across
// twenty languages.
type PluginError struct {
	Code    string
	Text    string
	Details map[string]any
	message string
}

func (e *PluginError) Error() string { return e.message }

// Fail builds the error the canonical would have thrown. Go RETURNS it;
// every caller in this port propagates rather than unwinding.
func Fail(code string, text string, details map[string]any) *PluginError {
	if nil == details {
		details = map[string]any{}
	}
	return &PluginError{
		Code:    code,
		Text:    text,
		Details: details,
		message: FormatError(code, text, details),
	}
}

// CodeOf reports the §12 code of an error, or "" for an error this
// library did not raise. The corpus compares by code, so the driver
// needs one place that knows how to read it.
func CodeOf(err error) string {
	if pe, ok := err.(*PluginError); ok {
		return pe.Code
	}
	return ""
}
