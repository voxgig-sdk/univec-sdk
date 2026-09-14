// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/ref.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Identity: name+tag, written `name$tag` (§4).
 *
 * The four pure functions, and the whole of what `ref` pins. They are
 * the first thing a new port implements and the first corpus section it
 * passes. */

package plugin

import (
	"regexp"
	"strings"
)

// §4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024.
var nameRe = regexp.MustCompile(`^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`)

// §4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
//
// The asymmetry with a name is deliberate: a tag MAY start with a digit
// because auto-tagging assigns integer tags (`stripe$1`), and a tag
// admits neither `@` nor `/` because a name is a package specifier and a
// tag is not.
var tagRe = regexp.MustCompile(`^[a-zA-Z0-9.~_-]+$`)

const refMax = 1024

func CheckName(name string) bool {
	if 0 == len(name) || refMax < len(name) {
		return false
	}
	return nameRe.MatchString(name)
}

func CheckTag(tag string) bool {
	// The empty tag is an ordinary tag (§4 rule 2). The single-instance
	// case writes no tag and never learns tags exist.
	if 0 == len(tag) {
		return true
	}
	if refMax < len(tag) {
		return false
	}
	return tagRe.MatchString(tag)
}

// ParseRef turns `name$tag` into the pair. Canonicalizing: `stripe$` and
// `stripe` both give tag "".
func ParseRef(str string) (Ref, error) {
	// Split on the FIRST `$`. Nothing in the grammar decides this — `$`
	// is in neither character class — so the corpus is the arbiter (§4
	// rule 5), and it picks the split that blames the part actually at
	// fault: `a$b$c` is a good name with a bad tag, not the reverse.
	name := str
	tag := ""
	if cut := strings.Index(str, "$"); -1 != cut {
		name = str[:cut]
		tag = str[cut+1:]
	}

	if !CheckName(name) {
		return Ref{}, Fail("plugin_bad_name", "invalid plugin name: "+name,
			map[string]any{"name": name})
	}
	if !CheckTag(tag) {
		return Ref{}, Fail("plugin_bad_tag", "invalid plugin tag: "+tag,
			map[string]any{"name": name, "tag": tag})
	}

	return Ref{Name: name, Tag: tag}, nil
}

// FormatRef turns the pair into `name$tag`. An empty tag NEVER writes
// the separator, which is the half of canonicalization FormatRef owns:
// parse tolerates `stripe$`, format never produces it, so a round trip
// is idempotent.
func FormatRef(name string, tag string) (string, error) {
	if !CheckName(name) {
		return "", Fail("plugin_bad_name", "invalid plugin name: "+name,
			map[string]any{"name": name})
	}
	if !CheckTag(tag) {
		return "", Fail("plugin_bad_tag", "invalid plugin tag: "+tag,
			map[string]any{"name": name, "tag": tag})
	}
	if "" == tag {
		return name, nil
	}
	return name + "$" + tag, nil
}

// CanonRef is the canonical spelling of a ref. §4 rule 5: ports must
// canonicalize before comparison.
func CanonRef(str string) (string, error) {
	r, err := ParseRef(str)
	if nil != err {
		return "", err
	}
	return FormatRef(r.Name, r.Tag)
}

// canon is CanonRef for the many internal callers that have already
// established the ref is well formed, or that want the input back
// unchanged when it is not. NEVER use it where a bad ref must be
// reported — the corpus pins plugin_bad_name at every public entry.
func canon(str string) string {
	c, err := CanonRef(str)
	if nil != err {
		return str
	}
	return c
}

// refname is the name half, for the internal callers that only compare.
func refname(str string) string {
	r, err := ParseRef(str)
	if nil != err {
		return str
	}
	return r.Name
}
