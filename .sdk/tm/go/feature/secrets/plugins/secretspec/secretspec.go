// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (go/plugins/secretspec/secretspec.go)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
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
