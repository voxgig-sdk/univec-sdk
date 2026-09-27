// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/types.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package plugin

import (
	"bytes"
	"encoding/json"
	"fmt"
)

type Ref struct {
	Name string `json:"name"`
	Tag  string `json:"tag"`
}

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

type OrderBlock struct {
	Before OrderRef `json:"before,omitempty"`
	After  OrderRef `json:"after,omitempty"`
	Band   *int     `json:"band,omitempty"`
}

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

	return marshal(out)
}

type OrderRef struct {
	raw  any
	list []string
	set  bool
}

func (ref OrderRef) Refs() []string {
	out := make([]string, len(ref.list))
	copy(out, ref.list)

	return out
}

func (ref *OrderRef) UnmarshalJSON(data []byte) error {
	var authored any

	if err := json.Unmarshal(data, &authored); nil != err {
		return err
	}

	*ref = asorderref(authored, true)

	return nil
}

func (ref OrderRef) Stated() bool {
	return ref.set
}

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

type Instance struct {
	Pos          int         `json:"pos"`
	Active       bool        `json:"active"`
	Start        string      `json:"start"`
	Order        *OrderBlock `json:"order,omitempty"`
	OptionLayers []any       `json:"optionlayers"`
}

type Normalized struct {
	Instance map[string]*Instance `json:"instance"`
	Order    []string             `json:"order"`
	Default  map[string]any       `json:"default"`
}

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

type PluginError struct {
	Code    string
	Text    string
	Details map[string]any
	message string
}

func (e *PluginError) Error() string { return e.message }

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
