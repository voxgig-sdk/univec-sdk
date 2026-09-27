// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (go/plugins/minivault/minivault.go)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package minivault

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"

	plugin "GOMODULE/feature/secrets/plugin"

	"GOMODULE/feature/secrets/sekreto"
)

var (
	locksmu sync.Mutex
	locks   = map[string]*sync.Mutex{}
)

func lockfor(file string) *sync.Mutex {
	key, err := filepath.Abs(file)
	if nil != err {
		key = file
	}

	locksmu.Lock()
	defer locksmu.Unlock()

	lock, has := locks[key]
	if !has {
		lock = &sync.Mutex{}
		locks[key] = lock
	}

	return lock
}

// KeyInfo is what a key may do. Grants is empty for a master key, which
// reads and writes every name there is.
type KeyInfo struct {
	Key    string   `json:"key"`
	Master bool     `json:"master"`
	Write  bool     `json:"write"`
	Grants []string `json:"grants"`
}

type GrantSpec struct {
	Key string
	// Passphrase is what unwraps it. Nothing else does, and no master can
	// recover it - a lost restricted passphrase is re-granted, never read
	// back.
	Passphrase string
	// Names the key may read. A name that does not exist yet is allowed
	// and means what it says: the key reads it once a master writes it.
	Names      []string
	Write      bool
	Iterations int
}

type Options struct {
	File       string
	Key        string
	Passphrase string
	// Iterations is the PBKDF2 round count used when this handle CREATES
	// a key. Reading uses what the file records for the key being opened.
	Iterations int
	Create     bool
}

type ring struct {
	V      int                `json:"v"`
	Write  bool               `json:"write"`
	Root   string             `json:"root,omitempty"`
	Grants *map[string]string `json:"grants,omitempty"`
}

// orempty is the read side of that pointer: an absent `grants` and an
// empty one mean the same thing to a reader, and only the writer has to
// tell them apart.
func orempty(held *map[string]string) *map[string]string {
	if nil != held {
		return held
	}
	empty := map[string]string{}
	return &empty
}

// meta is what a master recorded about a key when it minted it, sealed
// under the vault's meta key so that Keys can answer without holding any
// other key's passphrase.
type meta struct {
	V      int      `json:"v"`
	Master bool     `json:"master"`
	Write  bool     `json:"write"`
	Grants []string `json:"grants"`
}

type Vault struct {
	file       string
	key        string
	passphrase string
	iterations int
	create     bool

	// Guards the derived state below. A Sekreto may resolve from several
	// goroutines, and two of them deriving the same ring concurrently is
	// wasted work at best and a torn map at worst.
	mu     sync.Mutex
	info   *KeyInfo
	root   []byte
	grants map[string][]byte
	// THE SEALED RING THIS WAS DERIVED FROM, kept so that every later
	// call can check the file still says the same thing. A handle that
	// cached its keys and never looked again kept reading a vault after
	// its key was revoked, which is the one thing Revoke promises.
	ring *sealed

	// write serializes this handle's writes with every other handle on
	// the same file in this process.
	write *sync.Mutex
}

// copyinfo is a detached copy, so that what a caller is handed cannot
// become what this vault believes.
func copyinfo(info *KeyInfo) *KeyInfo {
	return &KeyInfo{
		Key:    info.Key,
		Master: info.Master,
		Write:  info.Write,
		Grants: append([]string{}, info.Grants...),
	}
}

func sameseal(left *sealed, right *sealed) bool {
	return bytes.Equal(left.IV, right.IV) && bytes.Equal(left.Blob, right.Blob)
}

func Open(options *Options) (*Vault, error) {
	if nil == options || "" == options.File {
		return nil, fail("a vault needs a file")
	}
	if "" == options.Passphrase {
		return nil, fail("a vault needs a passphrase")
	}

	key := options.Key
	if "" == key {
		key = MasterKey
	}

	iterations := options.Iterations
	if 0 >= iterations {
		iterations = Iterations
	}

	if err := checkid(key, "a vault needs a key id"); nil != err {
		return nil, err
	}

	return &Vault{
		file:       options.File,
		key:        key,
		passphrase: options.Passphrase,
		iterations: iterations,
		create:     options.Create,
		write:      lockfor(options.File),
	}, nil
}

// Create makes a vault file and returns a handle on its master key.
//
// Refuses a file that is already there: a vault is created once, and
// overwriting one discards every secret in it along with every key that
// could read them.
func Create(options *Options) (*Vault, error) {
	vault, err := Open(options)
	if nil != err {
		return nil, err
	}

	fresh, err := newvault(vault.key, vault.passphrase, vault.iterations)
	if nil != err {
		return nil, err
	}

	if err := putnew(vault.file, fresh); nil != err {
		return nil, err
	}

	return vault, nil
}

func (vault *Vault) File() string { return vault.file }

func (vault *Vault) Key() string { return vault.key }

func (vault *Vault) Info() (*KeyInfo, error) {
	vault.mu.Lock()
	defer vault.mu.Unlock()

	_, info, err := vault.load()
	if nil != err {
		return nil, err
	}

	return copyinfo(info), nil
}

func (vault *Vault) Close() {
	vault.mu.Lock()
	defer vault.mu.Unlock()

	vault.info = nil
	vault.root = nil
	vault.grants = nil
	vault.ring = nil
}

func (vault *Vault) bytes() ([]byte, error) {
	raw, err := os.ReadFile(vault.file)
	if nil == err {
		return raw, nil
	}

	if os.IsNotExist(err) {
		if !vault.create {
			return nil, fail("no vault file: " + vault.file)
		}

		fresh, err := newvault(vault.key, vault.passphrase, vault.iterations)
		if nil != err {
			return nil, err
		}
		if err := putnew(vault.file, fresh); nil != err {
			return nil, err
		}

		return os.ReadFile(vault.file)
	}

	return nil, fail("cannot read " + vault.file + ": " + err.Error())
}

// load reads the file and, the first time, unwraps this key's ring.
// Callers hold vault.mu.
func (vault *Vault) load() (*vaultFile, *KeyInfo, error) {
	raw, err := vault.bytes()
	if nil != err {
		return nil, nil, err
	}

	file, err := readfile(raw)
	if nil != err {
		return nil, nil, err
	}

	record := file.key(vault.key)
	if nil == record {
		// REVOKED, or never there. Either way this handle is finished,
		// and dropping what it derived is what stops the next call
		// answering from memory.
		vault.info, vault.root, vault.grants, vault.ring = nil, nil, nil, nil
		return nil, nil, fail("no such key: " + vault.key)
	}

	// The file still holds this key, and holds the SAME ring: a key
	// revoked and re-granted under another passphrase is a different key
	// wearing the id, and re-deriving is what refuses it.
	if nil != vault.info && nil != vault.ring && sameseal(vault.ring, record.Ring) {
		return file, vault.info, nil
	}
	vault.info, vault.root, vault.grants, vault.ring = nil, nil, nil, nil

	plain, err := unseal(kek(vault.passphrase, record.Salt, record.Iters), record.Ring,
		aadRing+vault.key, "wrong passphrase for key "+vault.key+", or a damaged vault")
	if nil != err {
		return nil, nil, err
	}

	held := &ring{}
	if err := jsonof(plain, held, "key ring for "+vault.key); nil != err {
		return nil, nil, err
	}

	grants := map[string][]byte{}
	names := []string{}
	held.Grants = orempty(held.Grants)
	for name, key := range *held.Grants {
		raw, err := unb64(key, "a granted key")
		if nil != err {
			return nil, nil, err
		}
		grants[name] = raw
		names = append(names, name)
	}
	sort.Strings(names)

	root := []byte(nil)
	if "" != held.Root {
		if root, err = unb64(held.Root, "the root key"); nil != err {
			return nil, nil, err
		}
	}

	vault.root = root
	vault.grants = grants
	vault.ring = record.Ring
	vault.info = &KeyInfo{
		Key:    vault.key,
		Master: nil != root,
		Write:  nil != root || held.Write,
		Grants: names,
	}

	return file, vault.info, nil
}

func (vault *Vault) rootof(what string) ([]byte, error) {
	if nil == vault.root {
		return nil, fail(what + " needs a master key, and " + vault.key + " is restricted")
	}
	return vault.root, nil
}

// keyfor is the key for one name, or nil when this key cannot reach it.
func (vault *Vault) keyfor(name string) []byte {
	if nil != vault.root {
		return secretkey(vault.root, name)
	}
	return vault.grants[name]
}

func (vault *Vault) save(file *vaultFile) error {
	suffix, err := random(8)
	if nil != err {
		return err
	}

	temp := vault.file + "." + hex.EncodeToString(suffix) + ".tmp"

	handle, err := os.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if nil != err {
		return fail("cannot write " + vault.file + ": " + err.Error())
	}

	if _, err := handle.Write(writefile(file)); nil != err {
		handle.Close()
		os.Remove(temp)
		return fail("cannot write " + vault.file + ": " + err.Error())
	}

	if err := handle.Close(); nil != err {
		os.Remove(temp)
		return fail("cannot write " + vault.file + ": " + err.Error())
	}

	if err := os.Rename(temp, vault.file); nil != err {
		// The vault is unchanged either way, and the write error is what
		// the caller needs to be told about.
		os.Remove(temp)
		return fail("cannot write " + vault.file + ": " + err.Error())
	}

	return nil
}

// --- reading secrets -------------------------------------------------

func (vault *Vault) List() ([]string, error) {
	vault.mu.Lock()
	defer vault.mu.Unlock()

	file, info, err := vault.load()
	if nil != err {
		return nil, err
	}

	names := []string{}

	if nil != vault.root {
		namekey := mac(vault.root, labelNames)
		for _, entry := range file.Entries {
			plain, err := unseal(namekey, entry.Name, aadName, "a secret name is damaged")
			if nil != err {
				return nil, err
			}
			names = append(names, string(plain))
		}
	} else {
		// A restricted key has no name key, so it reports the grants it
		// can actually find: the vault never tells it what else is there.
		for _, name := range info.Grants {
			if nil != file.entry(entryid(vault.grants[name])) {
				names = append(names, name)
			}
		}
	}

	sort.Strings(names)

	return names, nil
}

// Get is the value, and whether this key could read it. A name the vault
// does not hold and a name this key was not granted are both a miss.
func (vault *Vault) Get(name string) (string, bool, error) {
	if err := sekreto.CheckName(name); nil != err {
		return "", false, err
	}

	vault.mu.Lock()
	defer vault.mu.Unlock()

	file, _, err := vault.load()
	if nil != err {
		return "", false, err
	}

	key := vault.keyfor(name)
	if nil == key {
		return "", false, nil
	}

	entry := file.entry(entryid(key))
	if nil == entry {
		return "", false, nil
	}

	plain, err := unseal(key, entry.Value, aadSecret+name, "the value of "+name+" is damaged")
	if nil != err {
		return "", false, err
	}

	return string(plain), true, nil
}

func (vault *Vault) Has(name string) (bool, error) {
	_, has, err := vault.Get(name)
	return has, err
}

// --- writing ---------------------------------------------------------

// Set writes a value. A master writes any name; a restricted key holding
// Write overwrites the names it was granted, and creates none.
func (vault *Vault) Set(name string, value string) error {
	if err := sekreto.CheckName(name); nil != err {
		return err
	}

	// Every write on this file, from any handle in this process,
	// serializes here; see lockfor.
	vault.write.Lock()
	defer vault.write.Unlock()

	vault.mu.Lock()
	defer vault.mu.Unlock()

	file, info, err := vault.load()
	if nil != err {
		return err
	}

	if !info.Write {
		return fail("key " + info.Key + " is read-only")
	}

	key := vault.keyfor(name)
	if nil == key {
		return fail("key " + info.Key + " was not granted " + name)
	}

	box, err := seal(key, []byte(value), aadSecret+name)
	if nil != err {
		return err
	}

	if entry := file.entry(entryid(key)); nil != entry {
		entry.Value = box
	} else {
		// A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
		// restricted key with Write updates what it was granted and
		// cannot grow the vault, which is what "restricted" has to mean
		// for the grant list to stay the whole story.
		root, err := vault.rootof("creating the secret " + name)
		if nil != err {
			return err
		}

		sealedname, err := seal(mac(root, labelNames), []byte(name), aadName)
		if nil != err {
			return err
		}

		file.Entries = append(file.Entries,
			&entryRecord{ID: entryid(key), Name: sealedname, Value: box})
	}

	return vault.save(file)
}

func (vault *Vault) Remove(name string) error {
	if err := sekreto.CheckName(name); nil != err {
		return err
	}

	// Every write on this file, from any handle in this process,
	// serializes here; see lockfor.
	vault.write.Lock()
	defer vault.write.Unlock()

	vault.mu.Lock()
	defer vault.mu.Unlock()

	file, _, err := vault.load()
	if nil != err {
		return err
	}

	root, err := vault.rootof("removing a secret")
	if nil != err {
		return err
	}

	want := entryid(secretkey(root, name))
	kept := []*entryRecord{}
	found := false

	for _, entry := range file.Entries {
		if !found && bytes.Equal(entry.ID, want) {
			found = true
			continue
		}
		kept = append(kept, entry)
	}

	if !found {
		return fail("no such secret: " + name)
	}

	file.Entries = kept

	return vault.save(file)
}

// --- keys ------------------------------------------------------------

func (vault *Vault) Keys() ([]*KeyInfo, error) {
	vault.mu.Lock()
	defer vault.mu.Unlock()

	file, _, err := vault.load()
	if nil != err {
		return nil, err
	}

	root, err := vault.rootof("listing the keys")
	if nil != err {
		return nil, err
	}

	metakey := mac(root, labelMeta)
	out := []*KeyInfo{}

	for _, record := range file.Keys {
		info := &KeyInfo{Key: record.ID, Grants: []string{}}

		plain, err := unseal(metakey, record.Meta, aadMeta+record.ID, "metadata")
		if nil == err {
			noted := &meta{}
			if err := jsonof(plain, noted, "metadata for key "+record.ID); nil != err {
				return nil, err
			}
			info.Master = noted.Master
			info.Write = noted.Write
			info.Grants = append([]string{}, noted.Grants...)
			sort.Strings(info.Grants)
		}
		// A record written under a root key this one has replaced. The
		// key is still in the file and still opens with its own
		// passphrase, so it is reported rather than hidden - with what it
		// can do unknown.

		out = append(out, info)
	}

	return out, nil
}

func (vault *Vault) Grant(spec *GrantSpec) error {
	// Every write on this file, from any handle in this process,
	// serializes here; see lockfor.
	vault.write.Lock()
	defer vault.write.Unlock()

	vault.mu.Lock()
	defer vault.mu.Unlock()

	file, _, err := vault.load()
	if nil != err {
		return err
	}

	root, err := vault.rootof("granting a key")
	if nil != err {
		return err
	}

	if nil == spec {
		return fail("a grant needs a key id")
	}
	if err := checkid(spec.Key, "a grant needs a key id"); nil != err {
		return err
	}
	if "" == spec.Passphrase {
		return fail("a grant needs a passphrase")
	}
	if nil != file.key(spec.Key) {
		return fail("key already exists: " + spec.Key)
	}

	names := append([]string{}, spec.Names...)
	sort.Strings(names)

	grants := map[string]string{}
	for _, name := range names {
		if err := sekreto.CheckName(name); nil != err {
			return err
		}
		grants[name] = b64(secretkey(root, name))
	}

	iterations := spec.Iterations
	if 0 >= iterations {
		iterations = vault.iterations
	}

	record, err := sealkey(root, spec.Key, spec.Passphrase, iterations,
		&ring{V: format, Write: spec.Write, Grants: &grants},
		&meta{V: format, Master: false, Write: spec.Write, Grants: names})
	if nil != err {
		return err
	}

	file.Keys = append(file.Keys, record)

	return vault.save(file)
}

// Revoke drops a key. Master only.
//
// Anyone who already copied the file keeps whatever that key could read,
// so revoking bars future reads of the LIVE file and Rotate is what
// takes a secret back.
func (vault *Vault) Revoke(key string) error {
	// Every write on this file, from any handle in this process,
	// serializes here; see lockfor.
	vault.write.Lock()
	defer vault.write.Unlock()

	vault.mu.Lock()
	defer vault.mu.Unlock()

	file, info, err := vault.load()
	if nil != err {
		return err
	}

	if _, err := vault.rootof("revoking a key"); nil != err {
		return err
	}

	if key == info.Key {
		return fail("a key cannot revoke itself: " + key)
	}

	if nil == file.key(key) {
		return fail("no such key: " + key)
	}

	kept := []*keyRecord{}
	for _, record := range file.Keys {
		if key != record.ID {
			kept = append(kept, record)
		}
	}
	file.Keys = kept

	return vault.save(file)
}

func (vault *Vault) Rotate() error {
	// Every write on this file, from any handle in this process,
	// serializes here; see lockfor.
	vault.write.Lock()
	defer vault.write.Unlock()

	vault.mu.Lock()
	defer vault.mu.Unlock()

	file, _, err := vault.load()
	if nil != err {
		return err
	}

	oldroot, err := vault.rootof("rotating the vault")
	if nil != err {
		return err
	}

	iters := file.key(vault.key).Iters

	oldnamekey := mac(oldroot, labelNames)
	held := [][2]string{}

	for _, entry := range file.Entries {
		plain, err := unseal(oldnamekey, entry.Name, aadName, "a secret name is damaged")
		if nil != err {
			return err
		}

		name := string(plain)
		key := secretkey(oldroot, name)

		value, err := unseal(key, entry.Value, aadSecret+name, "the value of "+name+" is damaged")
		if nil != err {
			return err
		}

		held = append(held, [2]string{name, string(value)})
	}

	root, err := random(keyLen)
	if nil != err {
		return err
	}

	namekey := mac(root, labelNames)
	entries := []*entryRecord{}

	for _, secret := range held {
		key := secretkey(root, secret[0])

		sealedname, err := seal(namekey, []byte(secret[0]), aadName)
		if nil != err {
			return err
		}

		box, err := seal(key, []byte(secret[1]), aadSecret+secret[0])
		if nil != err {
			return err
		}

		entries = append(entries, &entryRecord{ID: entryid(key), Name: sealedname, Value: box})
	}

	fresh, err := sealkey(root, vault.key, vault.passphrase, iters,
		&ring{V: format, Write: true, Root: b64(root)},
		&meta{V: format, Master: true, Write: true, Grants: []string{}})
	if nil != err {
		return err
	}

	if err := vault.save(&vaultFile{Keys: []*keyRecord{fresh}, Entries: entries}); nil != err {
		return err
	}

	vault.root = root
	vault.grants = map[string][]byte{}
	vault.info = &KeyInfo{Key: vault.key, Master: true, Write: true, Grants: []string{}}

	return nil
}

// --- making one ------------------------------------------------------

func sealkey(
	root []byte, id string, passphrase string, iters int, held *ring, noted *meta,
) (*keyRecord, error) {
	salt, err := random(saltLen)
	if nil != err {
		return nil, err
	}

	sealedring, err := seal(kek(passphrase, salt, iters), tojson(held), aadRing+id)
	if nil != err {
		return nil, err
	}

	sealedmeta, err := seal(mac(root, labelMeta), tojson(noted), aadMeta+id)
	if nil != err {
		return nil, err
	}

	return &keyRecord{ID: id, Salt: salt, Iters: iters, Ring: sealedring, Meta: sealedmeta}, nil
}

func newvault(keyid string, passphrase string, iterations int) (*vaultFile, error) {
	root, err := random(keyLen)
	if nil != err {
		return nil, err
	}

	record, err := sealkey(root, keyid, passphrase, iterations,
		&ring{V: format, Write: true, Root: b64(root)},
		&meta{V: format, Master: true, Write: true, Grants: []string{}})
	if nil != err {
		return nil, err
	}

	return &vaultFile{Keys: []*keyRecord{record}, Entries: []*entryRecord{}}, nil
}

func putnew(file string, vault *vaultFile) error {
	handle, err := os.OpenFile(file, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if nil != err {
		if os.IsExist(err) {
			return fail("vault file already exists: " + file)
		}
		return fail("cannot write " + file + ": " + err.Error())
	}

	if _, err := handle.Write(writefile(vault)); nil != err {
		handle.Close()
		os.Remove(file)
		return fail("cannot write " + file + ": " + err.Error())
	}

	if err := handle.Close(); nil != err {
		return fail("cannot write " + file + ": " + err.Error())
	}

	return nil
}

// --- base64 and json -------------------------------------------------

func b64(raw []byte) string {
	return base64.StdEncoding.EncodeToString(raw)
}

func unb64(text string, what string) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(text)
	if nil != err {
		return nil, fail("missing " + what)
	}
	return raw, nil
}

func tojson(value any) []byte {
	raw, err := json.Marshal(value)
	if nil != err {
		return []byte("{}")
	}
	return raw
}

// --- the provider ----------------------------------------------------

type Provider struct {
	Vault *Vault
}

func (provider *Provider) Lookup(name string) (string, bool, error) {
	return provider.Vault.Get(name)
}

func (provider *Provider) Describe() string {
	return "minivault:" + provider.Vault.File()
}

// VaultExport is the export key the vault API is published under, beside
// the `provider` key every kind publishes.
const VaultExport = "vault"

var Plugin = plugin.Definition{
	Name: "minivault",
	Define: func(inst *plugin.Inst) error {
		spec, err := sekreto.SpecOf(inst.Options())
		if nil != err {
			return err
		}

		// Configuration is refused HERE, so a mistyped chain fails at
		// construction. Reaching the file is not configuration: the
		// handle is lazy, and nothing is read or stretched until a
		// lookup.
		vault, err := Open(&Options{
			File:       spec.File,
			Key:        spec.VaultKey,
			Passphrase: spec.Passphrase,
			Iterations: spec.Iterations,
			Create:     spec.Create,
		})
		if nil != err {
			return wrap(inst, err)
		}

		inst.Export(sekreto.ProviderExport, &Provider{Vault: vault})
		inst.Export(VaultExport, vault)

		return nil
	},
}

func wrap(inst *plugin.Inst, err error) error {
	serr, is := err.(*sekreto.SekretoError)
	if !is {
		return err
	}
	return plugin.Fail(sekreto.ErrorCode, serr.Message,
		map[string]any{"ref": inst.Ref(), "cause": serr.Message})
}

func VaultOf(sek *sekreto.Sekreto, store string) (*Vault, error) {
	if "" == store {
		found, err := sek.Host().Exports("minivault/" + VaultExport)
		if nil != err {
			return nil, err
		}
		vault, is := found.(*Vault)
		if !is {
			return nil, fail("no minivault store in this chain")
		}
		return vault, nil
	}

	ref := "minivault"
	if "minivault" != store {
		ref = "minivault$" + store
	}

	if live, err := sek.Host().Instance(ref); nil != err || nil == live {
		return nil, fail("no minivault store named " + store + " in this chain")
	}

	found, err := sek.Host().Exports(ref + "/" + VaultExport)
	if nil != err {
		return nil, err
	}

	vault, is := found.(*Vault)
	if !is {
		return nil, fail("no minivault store named " + store + " in this chain")
	}

	return vault, nil
}
