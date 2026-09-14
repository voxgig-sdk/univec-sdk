// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/plugins/secretspec/secretspec.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The secretspec plugin: SecretSpec, through its CLI. Needs a child
// process. A port of typescript/plugins/secretspec.ts.
package secretspec

import (
	"bytes"
	"errors"
	"os/exec"
	"strconv"
	"strings"

	"GOMODULE/feature/secrets/sekreto"
)

// Provider reads SecretSpec (https://secretspec.dev).
//
// SecretSpec is a declaration - a secretspec.toml naming the secrets a
// project needs - plus a chain of its own backends to satisfy them from.
// That makes it the same shape as sekreto one level down, and the reason to
// support it is the same reason sekreto exists: a project that has already
// declared its secrets there should not have to declare them again here.
//
// Read through its CLI, as boru is, because that is the interface it offers
// a program in another language: `secretspec get API_TOKEN` prints the value
// on stdout and nothing else. A sekreto name maps to a SecretSpec key
// exactly as it maps to an environment variable - api.token is API_TOKEN -
// which is the convention SecretSpec's own examples use.
//
// Backend selects one of SecretSpec's backends (--provider, e.g. `keyring`
// or `dotenv://.env`) and is called Backend here only because Provider
// already means something else in this library.
//
// A reason is required, not optional: SecretSpec records every read in an
// audit log and refuses to read at all without one. sekreto sends `sekreto`
// unless told otherwise, so the audit trail says which tool asked.
type Provider struct {
	Command string
	File    string
	Profile string
	Backend string
	Reason  string
	Prefix  string
}

func (provider *Provider) command() string {
	if "" == provider.Command {
		return "secretspec"
	}
	return provider.Command
}

func (provider *Provider) Lookup(name string) (string, bool, error) {
	key, err := sekreto.EnvKey(name, provider.Prefix)
	if nil != err {
		return "", false, err
	}

	args := []string{}
	if "" != provider.File {
		args = append(args, "--file", provider.File)
	}
	args = append(args, "get", key)
	if "" != provider.Backend {
		args = append(args, "--provider", provider.Backend)
	}
	if "" != provider.Profile {
		args = append(args, "--profile", provider.Profile)
	}
	reason := provider.Reason
	if "" == reason {
		reason = "sekreto"
	}
	args = append(args, "--reason", reason)

	run := exec.Command(provider.command(), args...)

	var out, errout bytes.Buffer
	run.Stdout = &out
	run.Stderr = &errout

	runerr := run.Run()

	if nil == runerr {
		// The value and one newline, and nothing else.
		return strings.TrimSuffix(out.String(), "\n"), true, nil
	}

	var exiterr *exec.ExitError
	if !errors.As(runerr, &exiterr) {
		return "", false, sekreto.Fail("sekreto: cannot run " + provider.command() + ": " + runerr.Error())
	}

	why := strings.TrimSpace(errout.String())

	if secretspecmiss(why, key) {
		return "", false, nil
	}

	if "" == why {
		why = "exit " + strconv.Itoa(exiterr.ExitCode())
	}

	return "", false, sekreto.Fail("sekreto: secretspec error: " + why)
}

func (provider *Provider) Describe() string {
	if "" != provider.Backend {
		return "secretspec:" + provider.Backend
	}
	return "secretspec"
}

// secretspecmiss reports whether a SecretSpec failure means "no such secret"
// rather than "I could not answer".
//
// SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does not
// declare and one declared with no value, and both are misses: this store
// does not hold it, so the chain carries on.
//
// MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
// `Provider backend 'keyring' not found`, which is a store that could not
// answer at all - and reading that as a miss is the worst failure this
// library has, because the chain then falls through to a weaker store
// without saying so. The key is required to appear, so the two cannot be
// confused.
func secretspecmiss(why string, key string) bool {
	return strings.Contains(why, "Secret '"+key+"' not found")
}

// Plugin is the `secretspec` provider kind, as a voxgig/plugin definition.
var Plugin = sekreto.ProviderPlugin("secretspec", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
	return &Provider{
		Command: spec.Command,
		File:    spec.File,
		Profile: spec.Profile,
		Backend: spec.Backend,
		Reason:  spec.Reason,
		Prefix:  spec.Prefix,
	}, nil
})
