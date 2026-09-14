// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (go/sekreto/sekreto.go)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// sekreto: one interface for secrets, wherever they live.
//
// A Sekreto is an ordered chain of providers. Get asks each in turn and
// returns the first hit, so an app can be configured from environment
// variables in development and a vault in production without changing a
// line of its own code.
//
// A port of typescript/src/Sekreto.ts, which is canonical.
//
// Go has no exceptions, so where the canonical implementation throws a
// SekretoError this port returns one as an error value.
package sekreto

import (
	"bytes"
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"sync"

	plugin "GOMODULE/feature/secrets/plugin"
)

// SekretoError is anything sekreto refuses to do: a bad name, a missing
// secret, a provider that could not be reached.
type SekretoError struct {
	Message string
}

func (err *SekretoError) Error() string {
	return err.Message
}

// Fail is a SekretoError as an error value, for this package and for the
// plugins, which return their own refusals through it.
func Fail(message string) error {
	return &SekretoError{Message: message}
}

// WriteJSON is json.Marshal with Go's HTML escaping turned OFF.
//
// encoding/json escapes <, > and & as \u003c, \u003e and \u0026 unless
// told otherwise. That is a defence for JSON pasted into an HTML page,
// which this library never does, and it made go the only port whose bytes
// differed: every other port emits those three characters raw. The
// writer's output is part of what the ports agree on - the CLI line is
// compared byte for byte across all of them - so go matches the rest
// rather than the rest matching go.
//
// Encode appends a newline, which a JSON document does not carry, so it
// is trimmed. Use this for every value that LEAVES the process: a request
// body, a returned secret, the CLI's line. A marshal whose bytes are
// unmarshalled again without ever being emitted needs no such care.
func WriteJSON(value any) ([]byte, error) {
	var buf bytes.Buffer

	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)

	if err := enc.Encode(value); nil != err {
		return nil, err
	}

	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

var namepart = regexp.MustCompile(`^[a-z0-9_]+$`)

// ValidName reports whether this is a well-formed secret name.
func ValidName(name any) bool {
	text, is := name.(string)
	if !is || 0 == len(text) {
		return false
	}

	for _, part := range strings.Split(text, ".") {
		if !namepart.MatchString(part) {
			return false
		}
	}

	return true
}

// CheckName is ValidName as an error: the check every name-taking function
// makes before doing anything else, and the one a plugin makes before
// putting a name on a command line or in a URL.
func CheckName(name string) error {
	if !ValidName(name) {
		return Fail("sekreto: invalid name: " + name)
	}
	return nil
}

// EnvKey is the environment-variable key for a name: api.token -> API_TOKEN.
func EnvKey(name string, prefix string) (string, error) {
	if err := CheckName(name); nil != err {
		return "", err
	}

	return prefix + strings.ToUpper(strings.Join(strings.Split(name, "."), "_")), nil
}

// VaultRef is where a name lives in a KV vault: api.token -> api / token.
//
// A single-segment name has no path of its own, so it becomes a secret of
// that name with the conventional field `value`.
type VaultRef struct {
	Path  string `json:"path"`
	Field string `json:"field"`
}

// NameVaultRef splits a name into its vault path and field.
func NameVaultRef(name string) (*VaultRef, error) {
	if err := CheckName(name); nil != err {
		return nil, err
	}

	parts := strings.Split(name, ".")

	if 1 == len(parts) {
		return &VaultRef{Path: parts[0], Field: "value"}, nil
	}

	return &VaultRef{
		Path:  strings.Join(parts[:len(parts)-1], "/"),
		Field: parts[len(parts)-1],
	}, nil
}

// FlatName is a name flattened to one segment: api.token -> api_token (GCP
// Secret Manager, `_`) or api-token (Azure Key Vault, `-`).
//
// Those stores have no path hierarchy and reject dots in ids, so the dots
// become the store's conventional separator. With `-` as the separator,
// underscores flatten too: Azure Key Vault's alphabet is letters, digits
// and hyphens only, and a valid sekreto name like with_underscore must
// still be representable there. (The resulting `.`/`_` collision mirrors
// the documented EnvKey behaviour, where both already map to `_`.)
func FlatName(name string, sep string) (string, error) {
	if err := CheckName(name); nil != err {
		return "", err
	}

	flat := strings.Join(strings.Split(name, "."), sep)
	if "-" == sep {
		flat = strings.Join(strings.Split(flat, "_"), "-")
	}

	return flat, nil
}

// AwsParam is the AWS SSM Parameter Store name for a name: dots become the
// path hierarchy, rooted at `/` (or at a prefix): db.pass.main ->
// /db/pass/main, or /app/db/pass/main under prefix `/app`.
func AwsParam(name string, prefix string) (string, error) {
	if err := CheckName(name); nil != err {
		return "", err
	}

	base := prefix
	if "" != base && !strings.HasPrefix(base, "/") {
		base = "/" + base
	}
	base = strings.TrimSuffix(base, "/")

	return base + "/" + strings.Join(strings.Split(name, "."), "/"), nil
}

// ParseDotenv parses `.env` text into a map of raw keys to values.
//
// Deliberately small: KEY=value, optional `export`, `#` comments on their
// own line, and single- or double-quoted values (double quotes also
// unescape \n, \r, \t and \\). A line with no `=` is skipped.
func ParseDotenv(text string) map[string]string {
	out := map[string]string{}

	for _, rawline := range strings.Split(text, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(rawline, "\r"))

		if 0 == len(line) || strings.HasPrefix(line, "#") {
			continue
		}

		body := line
		if strings.HasPrefix(line, "export ") {
			body = strings.TrimSpace(line[7:])
		}

		eq := strings.Index(body, "=")
		if 0 >= eq {
			continue
		}

		key := strings.TrimSpace(body[:eq])
		value := strings.TrimSpace(body[eq+1:])

		if 2 <= len(value) && strings.HasPrefix(value, `"`) && strings.HasSuffix(value, `"`) {
			value = unescape(value[1 : len(value)-1])
		} else if 2 <= len(value) && strings.HasPrefix(value, "'") && strings.HasSuffix(value, "'") {
			value = value[1 : len(value)-1]
		}

		out[key] = value
	}

	return out
}

func unescape(text string) string {
	var out strings.Builder

	for index := 0; index < len(text); index++ {
		if '\\' == text[index] && index+1 < len(text) {
			next := text[index+1]
			index++
			switch next {
			case 'n':
				out.WriteByte('\n')
			case 'r':
				out.WriteByte('\r')
			case 't':
				out.WriteByte('\t')
			case '\\':
				out.WriteByte('\\')
			case '"':
				out.WriteByte('"')
			default:
				out.WriteByte('\\')
				out.WriteByte(next)
			}
		} else {
			out.WriteByte(text[index])
		}
	}

	return out.String()
}

// Redact replaces known secret values in text with `[redacted]`.
//
// Only values of four characters or more are replaced: shorter ones are too
// likely to appear in ordinary text, and redacting them would make logs
// unreadable without making them safer.
func Redact(text string, values []string) string {
	out := text

	// A copy: `values` belongs to the caller (it is `seen` when called
	// through Sekreto.Redact), and sorting in place would reorder it.
	usable := []string{}
	for _, value := range values {
		if 4 <= len(value) {
			usable = append(usable, value)
		}
	}
	sort.SliceStable(usable, func(left, right int) bool {
		return len(usable[left]) > len(usable[right])
	})

	for _, value := range usable {
		out = strings.Join(strings.Split(out, value), "[redacted]")
	}

	return out
}

// Options configure a Sekreto.
type Options struct {
	// Providers is the chain, in resolution order. Each entry names a kind
	// to build - a built-in, or a plugin passed in Plugins - or carries a
	// Provider already built.
	Providers []*ProviderSpec
	// Plugins is the provider kinds beyond the built-ins that Providers may
	// name, as voxgig/plugin definitions. Static and explicit: the calling
	// project imports the plugin packages it needs and passes them here,
	// and a kind it did not pass is unknown to this Sekreto.
	Plugins []plugin.Definition
	// NoCache disables the resolved-value cache.
	NoCache bool
}

// entry is one provider in the chain, under the store name it answers to,
// and the ref of the plugin instance that built it - "" for a provider
// handed in already built, which no instance backs.
type entry struct {
	store    string
	ref      string
	provider Provider
}

// cached is one resolved value. A slice, not a map: the store a value came
// from stays attached, and redaction order does not vary between runs.
type cached struct {
	store string
	name  string
	value string
}

// StoreName is the store name a provider answers to when nothing says
// otherwise.
//
// Describe opens with the provider's kind - hashicorp:..., dotenv:..., plain
// env - so the kind is the natural default, and a custom provider gets a
// sensible name without implementing anything extra.
func StoreName(provider Provider) string {
	return strings.SplitN(provider.Describe(), ":", 2)[0]
}

// unknownkind is the message for a kind the catalog does not hold.
//
// A kind sekreto has never heard of is a typo; a kind that exists as a
// plugin but was not passed in is the split working as designed and
// telling you what to pass. Collapsing the two was the first thing that
// made the split confusing to use.
func unknownkind(kind string, catalog *plugin.Catalog) string {
	message := "sekreto: unknown provider kind: " + kind +
		" (available: " + strings.Join(catalog.Names(), ", ") + ")"

	for _, known := range Kinds.Plugin {
		if known == kind {
			return message + " - " + kind +
				" is a sekreto plugin, not built in: pass it in the Plugins option"
		}
	}

	return message
}

// unwrap turns a SekretoError that crossed the plugin boundary back into
// itself, byte for byte. Anything else is not sekreto's to rewrite.
func unwrap(err error) error {
	perr, is := err.(*plugin.PluginError)
	if !is || ErrorCode != perr.Code {
		return err
	}

	cause, is := perr.Details["cause"].(string)
	if !is {
		return err
	}

	return Fail(cause)
}

// Sekreto is the secrets facade: a chain of providers plus a cache.
//
// Two ways to read. Get is transparent - it walks the chain and takes the
// first hit, and the caller never learns which store answered. GetFrom is
// directed - it names the store, and only that store is asked.
type Sekreto struct {
	// host is the voxgig/plugin host every spec'd provider is an instance
	// of, and catalog the definitions it can build: the built-ins plus
	// what Options.Plugins handed in.
	host    *plugin.Host
	catalog *plugin.Catalog

	entries []entry
	docache bool
	// Guards cache and seen. Four PROVIDERS were given a mutex for
	// concurrent resolution; the facade holding the results was not, so two
	// goroutines appending to seen from the same length silently dropped one
	// - and a value missing from seen is a value Redact hands straight back
	// into the log. Held only around the slices, never across a provider
	// Lookup, so lookups stay concurrent.
	mu    sync.Mutex
	cache []cached
	// Every value ever resolved, for Redact. Kept independently of the
	// read cache so that redaction still works when caching is off -
	// otherwise NoCache would silently disable Redact and leak secrets
	// to logs.
	seen []string
}

// New makes a Sekreto from options: a catalog of the built-in kinds plus
// the plugins, a voxgig/plugin host, and one instance of the right kind
// per chain entry. It fails on a kind the catalog does not hold, a store
// name that is not a valid tag, or a provider that refuses its own
// configuration.
func New(options *Options) (*Sekreto, error) {
	opts := options
	if nil == opts {
		opts = &Options{}
	}

	// Built-ins first, then the plugins, into one catalog: a plugin that
	// names a built-in kind replaces it, which is how a host substitutes
	// an implementation and never an accident, because the four names
	// are documented.
	catalog, err := plugin.MakeCatalog(append(Builtins(), opts.Plugins...)...)
	if nil != err {
		return nil, err
	}

	sek := &Sekreto{
		host:    plugin.MakeHost(plugin.HostOptions{Catalog: catalog}),
		catalog: catalog,
		entries: []entry{},
		docache: !opts.NoCache,
	}

	for _, spec := range opts.Providers {
		if nil == spec {
			continue
		}

		if nil != spec.Provider {
			store := spec.Name
			if "" == store {
				store = StoreName(spec.Provider)
			}
			sek.entries = append(sek.entries, entry{store: store, provider: spec.Provider})
			continue
		}

		one, err := sek.declare(spec)
		if nil != err {
			return nil, err
		}
		sek.entries = append(sek.entries, one)
	}

	return sek, nil
}

// declare is one chain entry, as a plugin instance.
//
// The instance is `kind` for a store named after its kind and `kind$store`
// otherwise - `hashicorp$prod` - so Host().List() reads like the chain. A
// store name that is already taken gets a numbered tag from the host
// instead, because two providers MAY share a store name (a directed read
// walks both) and an instance ref may not.
func (sek *Sekreto) declare(spec *ProviderSpec) (entry, error) {
	kind := spec.Kind

	if !sek.catalog.Has(kind) {
		return entry{}, Fail(unknownkind(kind, sek.catalog))
	}

	store := spec.Name
	if "" == store {
		store = kind
	}

	if !plugin.CheckTag(store) {
		return entry{}, Fail("sekreto: invalid store name: " + store)
	}

	ref := kind
	if store != kind {
		formatted, err := plugin.FormatRef(kind, store)
		if nil != err {
			return entry{}, err
		}
		ref = formatted
	}
	if taken, _ := sek.host.Instance(ref); nil != taken {
		tagged, err := sek.host.AutoTag(kind)
		if nil != err {
			return entry{}, err
		}
		ref = tagged
	}

	options, err := OptionsOf(spec)
	if nil != err {
		return entry{}, err
	}

	// Load runs the definition's Define, which builds the provider from
	// the spec; Activate takes the instance live. Nothing is contacted by
	// either: a provider opens nothing until its first Lookup.
	if _, err := sek.host.Load(ref, plugin.DeclareSpec{Options: options}); nil != err {
		return entry{}, unwrap(err)
	}
	if _, err := sek.host.Activate(ref); nil != err {
		return entry{}, unwrap(err)
	}

	exported, err := sek.host.Exports(ref + "/" + ProviderExport)
	if nil != err {
		return entry{}, err
	}

	provider, is := exported.(Provider)
	if !is {
		return entry{}, Fail("sekreto: plugin " + kind + " exported no provider")
	}

	return entry{store: store, ref: ref, provider: provider}, nil
}

// Host is the voxgig/plugin host every spec'd provider is an instance of.
// Read it for introspection - List names each store's ref and status - and
// nothing on it advances the chain.
func (sek *Sekreto) Host() *plugin.Host {
	return sek.host
}

// Catalog is the definitions this Sekreto can build: the built-ins plus
// what Options.Plugins handed in.
func (sek *Sekreto) Catalog() *plugin.Catalog {
	return sek.catalog
}

// Close tears the chain down: every plugin instance is deactivated and
// unloaded, in reverse, releasing whatever a provider acquired at
// activation. Afterwards there is nothing to read from - Get reports every
// secret unknown - and the cache is dropped, though Redact still knows
// every value that was ever resolved.
func (sek *Sekreto) Close() error {
	err := sek.host.Close()

	sek.mu.Lock()
	sek.entries = []entry{}
	sek.cache = nil
	sek.mu.Unlock()

	return err
}

// Get returns the secret, or an error if no provider has it.
func (sek *Sekreto) Get(name string) (string, error) {
	found, has, err := sek.Try(name)
	if nil != err {
		return "", err
	}

	if !has {
		return "", Fail("sekreto: unknown secret: " + name)
	}

	return found, nil
}

// Try returns the secret and whether any provider had it.
func (sek *Sekreto) Try(name string) (string, bool, error) {
	return sek.resolve("", name, sek.entries)
}

// GetFrom returns the secret from one named store, or an error if that store
// does not have it.
func (sek *Sekreto) GetFrom(store string, name string) (string, error) {
	found, has, err := sek.TryFrom(store, name)
	if nil != err {
		return "", err
	}

	if !has {
		return "", Fail("sekreto: unknown secret: " + store + ":" + name)
	}

	return found, nil
}

// TryFrom returns the secret from one named store, and whether that store
// had it.
//
// Naming a store that is not in the chain is an error, not a miss: Try
// already means "this store may not have it", so it cannot also mean "this
// store may not exist" without hiding a typo.
func (sek *Sekreto) TryFrom(store string, name string) (string, bool, error) {
	matching := []entry{}

	for _, one := range sek.entries {
		if one.store == store {
			matching = append(matching, one)
		}
	}

	if 0 == len(matching) {
		return "", false, Fail("sekreto: unknown store: " + store)
	}

	return sek.resolve(store, name, matching)
}

func (sek *Sekreto) resolve(store string, name string, entries []entry) (string, bool, error) {
	if err := CheckName(name); nil != err {
		return "", false, err
	}

	if sek.docache {
		sek.mu.Lock()
		for _, hit := range sek.cache {
			if hit.store == store && hit.name == name {
				value := hit.value
				sek.mu.Unlock()
				return value, true, nil
			}
		}
		sek.mu.Unlock()
	}

	for _, one := range entries {
		// Deliberately not under the lock: a provider Lookup is a network
		// round-trip, and serialising those would turn a chain resolved from
		// several goroutines into a queue. Two goroutines can therefore both
		// miss the cache and both fetch, which costs a duplicate read and is
		// otherwise harmless - the store is being asked the same question.
		found, has, err := one.provider.Lookup(name)
		if nil != err {
			return "", false, err
		}

		if has {
			sek.mu.Lock()
			if sek.docache {
				sek.cache = append(sek.cache, cached{store: store, name: name, value: found})
			}
			sek.seen = append(sek.seen, found)
			sek.mu.Unlock()
			return found, true, nil
		}
	}

	return "", false, nil
}

// Has reports whether any provider has this secret.
func (sek *Sekreto) Has(name string) (bool, error) {
	_, has, err := sek.Try(name)
	return has, err
}

// HasIn reports whether this named store has this secret.
func (sek *Sekreto) HasIn(store string, name string) (bool, error) {
	_, has, err := sek.TryFrom(store, name)
	return has, err
}

// All returns every named secret at once. Missing ones are an error.
func (sek *Sekreto) All(names []string) (map[string]string, error) {
	out := map[string]string{}

	for _, name := range names {
		found, err := sek.Get(name)
		if nil != err {
			return nil, err
		}
		out[name] = found
	}

	return out, nil
}

// Sources describes each provider, in resolution order.
func (sek *Sekreto) Sources() []string {
	out := []string{}

	for _, one := range sek.entries {
		out = append(out, one.provider.Describe())
	}

	return out
}

// Stores names each store that can be named by GetFrom, in resolution order
// and without repeats.
// String is what a Sekreto shows of itself when something prints it.
//
// fmt reflects into unexported fields, so %v and %+v reach cache and seen,
// which between them hold every value this chain has ever resolved - one
// ordinary log line writes every secret out. GoString covers %#v the same
// way. Neither reaches a value.
func (sek *Sekreto) String() string {
	return "Sekreto{stores: [" + strings.Join(sek.Stores(), " ") + "]}"
}

func (sek *Sekreto) GoString() string {
	return sek.String()
}

func (sek *Sekreto) Stores() []string {
	out := []string{}

	for _, one := range sek.entries {
		seen := false
		for _, already := range out {
			if already == one.store {
				seen = true
				break
			}
		}
		if !seen {
			out = append(out, one.store)
		}
	}

	return out
}

// Redact replaces every value this Sekreto has resolved with `[redacted]`.
//
// Works whether or not caching is enabled: the redaction list is kept
// independently of the read cache.
func (sek *Sekreto) Redact(text string) string {
	sek.mu.Lock()
	seen := make([]string, len(sek.seen))
	copy(seen, sek.seen)
	sek.mu.Unlock()

	return Redact(text, seen)
}

// Refresh drops cached values, so the next Get asks the providers again.
func (sek *Sekreto) Refresh() {
	sek.mu.Lock()
	sek.cache = nil
	sek.mu.Unlock()
}
