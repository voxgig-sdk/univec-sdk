// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (go/sekreto/providers.go)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
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

type Provider interface {
	Lookup(name string) (string, bool, error)
	Describe() string
}

type ProviderSpec struct {
	Kind           string            `json:"kind,omitempty"`
	Name           string            `json:"name,omitempty"`
	Prefix         string            `json:"prefix,omitempty"`
	File           string            `json:"file,omitempty"`
	Values         map[string]string `json:"values,omitempty"`
	Dir            string            `json:"dir,omitempty"`
	Addr           string            `json:"addr,omitempty"`
	Token          string            `json:"token,omitempty"`
	Mount          string            `json:"mount,omitempty"`
	KV             int               `json:"kv,omitempty"`
	VaultNamespace string            `json:"vaultnamespace,omitempty"`
	// Auth logs hashicorp in for a token instead of being handed one.
	Auth         *AuthSpec `json:"auth,omitempty"`
	Command      string    `json:"command,omitempty"`
	Namespace    string    `json:"namespace,omitempty"`
	Home         string    `json:"home,omitempty"`
	Profile      string    `json:"profile,omitempty"`
	Backend      string    `json:"backend,omitempty"`
	Reason       string    `json:"reason,omitempty"`
	Region       string    `json:"region,omitempty"`
	KeyID        string    `json:"keyid,omitempty"`
	Secret       string    `json:"secret,omitempty"`
	Session      string    `json:"session,omitempty"`
	Project      string    `json:"project,omitempty"`
	Vault        string    `json:"vault,omitempty"`
	Tenant       string    `json:"tenant,omitempty"`
	ClientID     string    `json:"clientid,omitempty"`
	ClientSecret string    `json:"clientsecret,omitempty"`
	// azure: where to log in / where IMDS answers. gcp: where the
	// metadata server answers. Overridable for tests and for clouds with
	// nonstandard endpoints.
	LoginAddr    string `json:"loginaddr,omitempty"`
	ImdsAddr     string `json:"imdsaddr,omitempty"`
	MetadataAddr string `json:"metadataaddr,omitempty"`
	ApiVersion   string `json:"apiversion,omitempty"`
	Config       string `json:"config,omitempty"`
	Environment  string `json:"environment,omitempty"`
	Path         string `json:"path,omitempty"`
	Passphrase   string `json:"passphrase,omitempty"`
	// VaultKey is which key in a minivault file to open with, defaulting
	// to `master`. Named apart from Key and KeyID because those already
	// mean a secret name and an AWS access key id.
	VaultKey   string `json:"vaultkey,omitempty"`
	Iterations int    `json:"iterations,omitempty"`
	Create     bool   `json:"create,omitempty"`

	Provider Provider `json:"-"`
}

// AuthSpec is how the hashicorp provider logs in for a token instead of
// being handed one.
type AuthSpec struct {
	Method   string `json:"method,omitempty"`
	Mount    string `json:"mount,omitempty"`
	Role     string `json:"role,omitempty"`
	Jwt      string `json:"jwt,omitempty"`
	JwtFile  string `json:"jwtfile,omitempty"`
	RoleID   string `json:"roleid,omitempty"`
	SecretID string `json:"secretid,omitempty"`
}

type EnvProvider struct {
	Prefix string
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

const ProviderExport = "provider"

const ErrorCode = "sekreto_error"

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

var Kinds = struct {
	Builtin []string
	Plugin  []string
}{
	Builtin: []string{"env", "memory", "dotenv", "file"},
	Plugin: []string{
		"hashicorp", "boru", "awssecrets", "awsparams", "gcpsecrets",
		"azuresecrets", "onepassword", "doppler", "infisical", "secretspec",
		"minivault",
	},
}
