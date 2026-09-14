// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/plugins/boru/boru.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The boru plugin: a boru vault through its CLI, or over `boru vault
// serve`. Needs a child process, or HTTPS in wire mode. A port of
// typescript/plugins/boru.ts.
package boru

import (
	"bytes"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"GOMODULE/feature/secrets/plugins/httpjson"
	"GOMODULE/feature/secrets/sekreto"
)

// Provider reads a boru vault (https://github.com/boru-lang/boru).
//
// Two ways in, both boru's own.
//
// With no Addr, the CLI: `boru vault get --reveal <alias>` prints the
// secret on stdout, and nothing else. The passphrase is read by boru itself
// from BORU_VAULT_PASSPHRASE; sekreto never accepts it as config and never
// puts it on a command line, where it would show up in the process table.
//
// With an Addr, boru's wire protocol: `boru vault serve` publishes a
// read-only, HashiCorp-shaped provision API (boru's
// design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
// from `boru vault grant`. A sekreto name is already a valid boru alias,
// and boru aliases keep their dots, so api.token is the single path segment
// api.token - not the api/token split a HashiCorp KV gets. The value is the
// `value` field. A 404 is a miss; anything else the server refuses (a
// revoked capability, a sealed vault) is an error.
//
// boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
// credential *broker*, built precisely so the caller never receives the
// credential. `vault serve` is the provision endpoint, built to hand the
// value back - that is the one sekreto uses.
type Provider struct {
	Command   string
	Namespace string
	Home      string
	Addr      string
	Token     string
	Mount     string
}

func (provider *Provider) command() string {
	if "" == provider.Command {
		return "boru"
	}
	return provider.Command
}

func (provider *Provider) wireaddr() string {
	return strings.TrimSuffix(provider.Addr, "/")
}

func (provider *Provider) wiremount() string {
	if "" == provider.Mount {
		return "secret"
	}
	return provider.Mount
}

func (provider *Provider) wirelookup(name string) (string, bool, error) {
	addr := provider.wireaddr()
	if err := sekreto.CheckAddr(addr); nil != err {
		return "", false, err
	}

	// The dotted name stays one segment: boru aliases keep their dots.
	alias := name
	if "" != provider.Namespace {
		alias = provider.Namespace + "/" + name
	}
	target := addr + "/v1/" + provider.wiremount() + "/data/" + alias

	status, body, err := httpjson.Get(target, map[string]string{"X-Vault-Token": provider.Token})
	if nil != err {
		return "", false, err
	}

	if http.StatusNotFound == status {
		return "", false, nil
	}

	if http.StatusOK != status {
		return "", false, sekreto.Fail("sekreto: boru serve error: " + strconv.Itoa(status) + ": " + target)
	}

	value := httpjson.Dig(body, "data", "data", "value")
	if nil == value {
		return "", false, nil
	}

	return httpjson.ToString(value), true, nil
}

func (provider *Provider) Lookup(name string) (string, bool, error) {
	if err := sekreto.CheckName(name); nil != err {
		return "", false, err
	}

	if "" != provider.Addr {
		return provider.wirelookup(name)
	}

	alias := name
	if "" != provider.Namespace {
		alias = provider.Namespace + ":" + name
	}

	run := exec.Command(provider.command(), "vault", "get", "--reveal", alias)

	if "" != provider.Home {
		run.Env = append(os.Environ(), "BORU_HOME="+provider.Home)
	}

	var out, errout bytes.Buffer
	run.Stdout = &out
	run.Stderr = &errout

	err := run.Run()

	if nil == err {
		// boru prints the value and one newline, and nothing else.
		return strings.TrimSuffix(out.String(), "\n"), true, nil
	}

	var exiterr *exec.ExitError
	if !errors.As(err, &exiterr) {
		return "", false, sekreto.Fail("sekreto: cannot run " + provider.command() + ": " + err.Error())
	}

	why := strings.TrimSpace(errout.String())

	// "no alias named" is boru saying it does not hold this secret, which is a
	// miss: the chain carries on to the next provider. A locked vault or a
	// wrong passphrase is not a miss - treating it as one would fall through
	// to a weaker store without saying so.
	if borumiss(why) {
		return "", false, nil
	}

	if "" == why {
		why = "exit " + strconv.Itoa(exiterr.ExitCode())
	}

	return "", false, sekreto.Fail("sekreto: boru vault error: " + why)
}

func (provider *Provider) Describe() string {
	if "" != provider.Addr {
		return "boru:" + provider.wireaddr()
	}
	if "" != provider.Namespace {
		return "boru:" + provider.Namespace
	}
	return "boru"
}

// borumiss reports whether a boru failure means "no such secret" rather than
// "I could not answer". Matched on boru's own wording for a missing alias.
func borumiss(why string) bool {
	return strings.Contains(why, "no alias named")
}

// Plugin is the `boru` provider kind, as a voxgig/plugin definition.
var Plugin = sekreto.ProviderPlugin("boru", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
	return &Provider{
		Command:   spec.Command,
		Namespace: spec.Namespace,
		Home:      spec.Home,
		Addr:      spec.Addr,
		Token:     spec.Token,
		Mount:     spec.Mount,
	}, nil
})
