// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/ref.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package plugin

import (
	"regexp"
	"strings"
)

var nameRe = regexp.MustCompile(`^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`)

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

func ParseRef(str string) (Ref, error) {
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
