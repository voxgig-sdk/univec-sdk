// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/sekreto/providers.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// What a provider is, what its declarative form looks like, how a provider
// kind becomes a voxgig/plugin definition - and the four BUILT-IN kinds.
//
// A provider answers one question: "do you have this secret?" It returns
// the value and whether it had it - a false means "ask the next one".
// Nothing else about a provider is visible to the caller, which is the
// point: an app reads `api.token` and never learns whether it came from the
// environment, a .env file, HashiCorp Vault, AWS, GCP, Azure or a boru
// vault.
//
// Two failure shapes, and they are never interchangeable. A store that does
// not hold the secret is a MISS (false) - the chain carries on. A store
// that could not answer - bad credentials, unreachable host, missing
// configuration - is an ERROR: falling through there would quietly reach
// for a weaker store.
//
// THIS PACKAGE IMPORTS NO net/http, NO crypto AND NO os/exec. What makes a
// kind built in is that it needs nothing of the platform beyond reading a
// local file; every kind that opens a socket, signs a request or spawns a
// process is a plugin under plugins/, its own package, linked only by a
// binary that imports it (docs/design/plugin-providers.md).
//
// A port of typescript/src/provider/support.ts and
// typescript/src/provider/builtin.ts, which are canonical.

package sekreto

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	plugin "GOMODULE/feature/secrets/plugin"
)

// Provider is a source of secrets.
type Provider interface {
	// Lookup returns the value and whether this provider has it.
	Lookup(name string) (string, bool, error)
	// Describe is a short description, shown by Sekreto.Sources.
	Describe() string
}

// ProviderSpec is the declarative form of a provider, as used in config and
// in the shared spec: a Kind naming a built-in or a plugin, plus that
// kind's own configuration.
//
// The JSON tags are the spec's own key names, and they are also how the
// spec reaches a plugin: New hands each spec to the voxgig/plugin host as
// the instance's options map, and the plugin's definition reads it back
// with SpecOf. `omitempty` keeps that map to the keys actually set.
//
// A spec may instead CARRY a provider already built - Provider set, Kind
// empty - which is how a custom provider that is not a plugin joins the
// chain. Its store name is Name, or the kind its Describe opens with.
type ProviderSpec struct {
	Kind string `json:"kind,omitempty"`
	// Name is the store name GetFrom addresses. Defaults to Kind.
	Name   string            `json:"name,omitempty"`
	Prefix string            `json:"prefix,omitempty"`
	File   string            `json:"file,omitempty"`
	Values map[string]string `json:"values,omitempty"`
	// Dir is the file provider's directory of one-secret-per-file entries.
	Dir string `json:"dir,omitempty"`
	// hashicorp / boru (wire) / gcp / 1password / doppler / infisical:
	// the base URL and the access token.
	Addr  string `json:"addr,omitempty"`
	Token string `json:"token,omitempty"`
	// Mount is the hashicorp / boru (wire) KV mount (default `secret`).
	Mount string `json:"mount,omitempty"`
	// KV is the hashicorp KV engine version, 1 or 2 (default 2).
	KV int `json:"kv,omitempty"`
	// VaultNamespace is the Vault Enterprise namespace (X-Vault-Namespace).
	VaultNamespace string `json:"vaultnamespace,omitempty"`
	// Auth logs hashicorp in for a token instead of being handed one.
	Auth *AuthSpec `json:"auth,omitempty"`
	// Command is the boru / secretspec executable to run (default: the
	// kind's own name).
	Command string `json:"command,omitempty"`
	// boru
	Namespace string `json:"namespace,omitempty"`
	Home      string `json:"home,omitempty"`
	// Profile is the secretspec profile to read (--profile).
	Profile string `json:"profile,omitempty"`
	// Backend is which of secretspec's OWN backends to read from
	// (--provider), e.g. `keyring` or `dotenv://.env`. Named Backend here
	// because Provider already means a sekreto provider.
	Backend string `json:"backend,omitempty"`
	// Reason is the audit reason recorded for a secretspec read
	// (--reason). SecretSpec refuses to read without one.
	Reason string `json:"reason,omitempty"`
	// aws: region and credentials; the standard AWS_* environment
	// variables fill whichever are not given.
	Region  string `json:"region,omitempty"`
	KeyID   string `json:"keyid,omitempty"`
	Secret  string `json:"secret,omitempty"`
	Session string `json:"session,omitempty"`
	// Project is the gcp / doppler / infisical project (GCP project id,
	// Doppler project slug, Infisical workspace id).
	Project string `json:"project,omitempty"`
	// Vault is the azure Key Vault name or full URL, or the 1password
	// vault name or id.
	Vault string `json:"vault,omitempty"`
	// azure: client-credential login. infisical: universal-auth login
	// (tenant is Azure-only).
	Tenant       string `json:"tenant,omitempty"`
	ClientID     string `json:"clientid,omitempty"`
	ClientSecret string `json:"clientsecret,omitempty"`
	// azure: where to log in / where IMDS answers. gcp: where the
	// metadata server answers. Overridable for tests and for clouds with
	// nonstandard endpoints.
	LoginAddr    string `json:"loginaddr,omitempty"`
	ImdsAddr     string `json:"imdsaddr,omitempty"`
	MetadataAddr string `json:"metadataaddr,omitempty"`
	// ApiVersion is the azure Key Vault API version (default 7.4).
	ApiVersion string `json:"apiversion,omitempty"`
	// Config is the doppler config slug (with Project).
	Config string `json:"config,omitempty"`
	// infisical: the environment slug and secret path.
	Environment string `json:"environment,omitempty"`
	Path        string `json:"path,omitempty"`

	// Provider is a provider already built, joining the chain as it is.
	// Never serialized: a live provider is not data.
	Provider Provider `json:"-"`
}

// AuthSpec is how the hashicorp provider logs in for a token instead of
// being handed one.
type AuthSpec struct {
	Method string `json:"method,omitempty"`
	// Mount is the auth mount, defaulting to the method name.
	Mount string `json:"mount,omitempty"`
	// kubernetes: the Vault role to log in as.
	Role string `json:"role,omitempty"`
	// Jwt is the service-account JWT itself (tests).
	Jwt string `json:"jwt,omitempty"`
	// JwtFile is where the JWT lives; the conventional pod path by
	// default.
	JwtFile string `json:"jwtfile,omitempty"`
	// approle: the role and secret ids.
	RoleID   string `json:"roleid,omitempty"`
	SecretID string `json:"secretid,omitempty"`
}

// EnvProvider reads environment variables: api.token from API_TOKEN.
type EnvProvider struct {
	Prefix string
	// Source overrides the process environment, for tests.
	Source map[string]string
}

func (provider *EnvProvider) Lookup(name string) (string, bool, error) {
	key, err := EnvKey(name, provider.Prefix)
	if nil != err {
		return "", false, err
	}

	if nil != provider.Source {
		value, has := provider.Source[key]
		return value, has, nil
	}

	value, has := os.LookupEnv(key)
	return value, has, nil
}

func (provider *EnvProvider) Describe() string {
	if "" != provider.Prefix {
		return "env:" + provider.Prefix
	}
	return "env"
}

// DotenvProvider reads a `.env` file once, keyed exactly like the
// environment.
type DotenvProvider struct {
	File   string
	Prefix string
	// Guards the memoised state below: a Sekreto may resolve from several
	// goroutines, and a racy map read is either a crash or a zero value - a
	// MISS where the store does hold the secret, which falls through to a
	// weaker store.
	mu     sync.Mutex
	values map[string]string
}

func (provider *DotenvProvider) load() (map[string]string, error) {
	provider.mu.Lock()
	defer provider.mu.Unlock()

	if nil == provider.values {
		text, err := os.ReadFile(provider.File)
		if nil != err {
			// An absent file - or an absent directory - means "no secrets
			// here", exactly like FileProvider. Anything else (permission
			// denied, an unreadable mount) is a store that could not
			// answer, and swallowing it would fall through to a weaker
			// store.
			if !errors.Is(err, fs.ErrNotExist) && !errors.Is(err, syscall.ENOTDIR) {
				return nil, Fail("sekreto: dotenv provider cannot read " +
					provider.File + ": " + err.Error())
			}
			provider.values = map[string]string{}
		} else {
			provider.values = ParseDotenv(string(text))
		}
	}

	return provider.values, nil
}

func (provider *DotenvProvider) Lookup(name string) (string, bool, error) {
	key, err := EnvKey(name, provider.Prefix)
	if nil != err {
		return "", false, err
	}

	values, err := provider.load()
	if nil != err {
		return "", false, err
	}

	value, has := values[key]
	return value, has, nil
}

func (provider *DotenvProvider) Describe() string {
	return "dotenv:" + provider.File
}

// MemoryProvider holds literal values, keyed like environment variables.
// The spec uses this to test chain behaviour without touching the outside
// world.
type MemoryProvider struct {
	Values map[string]string
	Prefix string
}

func (provider *MemoryProvider) Lookup(name string) (string, bool, error) {
	key, err := EnvKey(name, provider.Prefix)
	if nil != err {
		return "", false, err
	}

	value, has := provider.Values[key]
	return value, has, nil
}

func (provider *MemoryProvider) Describe() string {
	if "" != provider.Prefix {
		return "memory:" + provider.Prefix
	}
	return "memory"
}

// FileProvider reads a directory of one-secret-per-file entries, keyed
// like the environment: api.token reads <dir>/API_TOKEN.
//
// This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
// secret, and a systemd credentials directory, so those all work with no
// further configuration. One trailing newline is stripped - tools that
// write these files disagree about it, and a newline is never part of a
// secret on purpose.
type FileProvider struct {
	Dir    string
	Prefix string
}

func (provider *FileProvider) Lookup(name string) (string, bool, error) {
	key, err := EnvKey(name, provider.Prefix)
	if nil != err {
		return "", false, err
	}

	file := filepath.Join(provider.Dir, key)

	raw, err := os.ReadFile(file)
	if nil != err {
		// An absent file - or an absent directory - means "no secrets
		// here", exactly like a missing .env. Anything else (permission
		// denied, an unreadable mount) is a store that could not answer.
		if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) {
			return "", false, nil
		}
		return "", false, Fail("sekreto: file provider cannot read " + file + ": " + err.Error())
	}

	text := string(raw)
	if strings.HasSuffix(text, "\n") {
		text = strings.TrimSuffix(strings.TrimSuffix(text, "\n"), "\r")
	}

	return text, true, nil
}

func (provider *FileProvider) Describe() string {
	return "file:" + provider.Dir
}

// --- providers as voxgig/plugin definitions ----------------------------

// ProviderExport is the export key under which a provider definition
// publishes the provider it built. New reads `<ref>/provider` off the host.
const ProviderExport = "provider"

// ErrorCode is the voxgig/plugin error code a SekretoError travels under
// when a definition's Define returns it.
//
// plugin wraps a code-less error returned by a callback as
// `plugin_define_failed`, and keeps an error that already carries a code.
// A provider that refuses its own configuration - `kv: 3`, a missing
// project - returns a SekretoError, and that message is pinned by the
// spec byte for byte, so it must come back out of the host exactly as it
// went in. ProviderPlugin gives it this code on the way in; New turns it
// back into a SekretoError on the way out.
const ErrorCode = "sekreto_error"

// ProviderPlugin is a provider kind, as a voxgig/plugin definition.
//
// This is the whole bridge between the two libraries. The definition's
// Name is the Kind a ProviderSpec names; its Define reads the spec back
// off the instance's options, builds the provider with make, and exports
// it. Nothing runs at activate: a provider opens nothing until its first
// Lookup, so there is nothing to capture - a provider that does hold a
// resource acquires it there and lets the instance scope unwind it.
//
// Every built-in and every plugin is made this way, so a custom provider
// kind is one call:
//
//	sekreto.ProviderPlugin("mystore", func(spec *sekreto.ProviderSpec) (sekreto.Provider, error) {
//	    return &MyStore{Addr: spec.Addr}, nil
//	})
func ProviderPlugin(kind string, make func(spec *ProviderSpec) (Provider, error)) plugin.Definition {
	return plugin.Definition{
		Name: kind,
		Define: func(inst *plugin.Inst) error {
			spec, err := SpecOf(inst.Options())
			if nil != err {
				return err
			}

			provider, err := make(spec)
			if nil != err {
				var serr *SekretoError
				if errors.As(err, &serr) {
					return plugin.Fail(ErrorCode, serr.Message,
						map[string]any{"ref": inst.Ref(), "cause": serr.Message})
				}
				return err
			}

			inst.Export(ProviderExport, provider)
			return nil
		},
	}
}

// SpecOf reads a ProviderSpec back off a plugin instance's options map -
// the JSON shape OptionsOf produced, and the shape a config document
// would.
func SpecOf(options map[string]any) (*ProviderSpec, error) {
	// json.Marshal, not WriteJSON: these bytes are unmarshalled on the next
	// line and never leave the process, so HTML escaping cannot be observed
	// - Unmarshal reads \u003c back as <. WriteJSON is for what is emitted.
	text, err := json.Marshal(options)
	if nil != err {
		return nil, Fail("sekreto: unreadable provider options: " + err.Error())
	}

	spec := &ProviderSpec{}
	if err := json.Unmarshal(text, spec); nil != err {
		return nil, Fail("sekreto: unreadable provider options: " + err.Error())
	}

	return spec, nil
}

// OptionsOf is a ProviderSpec as a plugin instance's options map: its
// JSON form, which is the spec's own key names.
func OptionsOf(spec *ProviderSpec) (map[string]any, error) {
	text, err := json.Marshal(spec)
	if nil != err {
		return nil, Fail("sekreto: unwritable provider spec: " + err.Error())
	}

	options := map[string]any{}
	if err := json.Unmarshal(text, &options); nil != err {
		return nil, Fail("sekreto: unwritable provider spec: " + err.Error())
	}

	return options, nil
}

// Builtins is the four built-in provider kinds, as definitions, in a fresh
// slice: env, memory, dotenv and file - the same four in every port. New
// puts them in every catalog ahead of the plugins it is handed.
func Builtins() []plugin.Definition {
	return []plugin.Definition{
		ProviderPlugin("env", func(spec *ProviderSpec) (Provider, error) {
			return &EnvProvider{Prefix: spec.Prefix}, nil
		}),
		ProviderPlugin("memory", func(spec *ProviderSpec) (Provider, error) {
			values := spec.Values
			if nil == values {
				values = map[string]string{}
			}
			return &MemoryProvider{Values: values, Prefix: spec.Prefix}, nil
		}),
		ProviderPlugin("dotenv", func(spec *ProviderSpec) (Provider, error) {
			file := spec.File
			if "" == file {
				file = ".env"
			}
			return &DotenvProvider{File: file, Prefix: spec.Prefix}, nil
		}),
		ProviderPlugin("file", func(spec *ProviderSpec) (Provider, error) {
			return &FileProvider{Dir: spec.Dir, Prefix: spec.Prefix}, nil
		}),
	}
}

// Kinds is every kind this library ships, built in or as a plugin, so that
// an unknown kind can be told from a plugin that was not loaded.
var Kinds = struct {
	Builtin []string
	Plugin  []string
}{
	Builtin: []string{"env", "memory", "dotenv", "file"},
	Plugin: []string{
		"hashicorp", "boru", "awssecrets", "awsparams", "gcpsecrets",
		"azuresecrets", "onepassword", "doppler", "infisical", "secretspec",
	},
}
