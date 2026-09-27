// VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (go/plugins/minivault/format.go)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package minivault

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"sort"
	"strconv"

	"GOMODULE/feature/secrets/sekreto"
)

const (
	magic  = "SKMV"
	format = 1

	kdfPBKDF2    = 1
	cipherAESGCM = 1
)

// AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.
const (
	keyLen  = 32
	ivLen   = 12
	tagLen  = 16
	saltLen = 16
)

// Iterations is the PBKDF2-HMAC-SHA256 round count when a caller names
// none.
const Iterations = 210000

// MasterKey is the key id a vault gets when a caller names none.
const MasterKey = "master"

// Additional authenticated data. Every blob is bound to its PLACE in the
// file, so no ciphertext can be moved: a restricted key's ring cannot be
// relabelled as the master's, and one secret's value cannot be served
// under a name it was never written for.
const (
	aadRing   = "skmv1:ring:"
	aadMeta   = "skmv1:meta:"
	aadName   = "skmv1:name"
	aadSecret = "skmv1:secret:"
)

// Everything a master reaches is derived from the root key, so rotating
// is one new random value rather than a re-wrap of each part.
const (
	labelNames = "skmv1:names"
	labelMeta  = "skmv1:meta"
	labelID    = "skmv1:id"
)

func fail(text string) error {
	return sekreto.Fail("sekreto: minivault: " + text)
}

const idMax = 255

func checkid(id string, what string) error {
	if "" == id {
		return fail(what)
	}
	if idMax < len(id) {
		cut := id
		if 32 < len(cut) {
			cut = cut[:32]
		}
		return fail("key id is longer than " + strconv.Itoa(idMax) + " bytes: " + cut + "...")
	}
	return nil
}

// --- keys ------------------------------------------------------------

func mac(key []byte, text string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(text))
	return h.Sum(nil)
}

func pbkdf2sha256(passphrase string, salt []byte, iters int, length int) []byte {
	out := []byte{}
	block := make([]byte, 4)

	for counter := 1; len(out) < length; counter++ {
		binary.BigEndian.PutUint32(block, uint32(counter))

		h := hmac.New(sha256.New, []byte(passphrase))
		h.Write(salt)
		h.Write(block)
		u := h.Sum(nil)

		t := make([]byte, len(u))
		copy(t, u)

		for round := 1; round < iters; round++ {
			h := hmac.New(sha256.New, []byte(passphrase))
			h.Write(u)
			u = h.Sum(nil)
			for index := range t {
				t[index] ^= u[index]
			}
		}

		out = append(out, t...)
	}

	return out[:length]
}

// kek is the key-encryption key a passphrase unwraps a ring with.
func kek(passphrase string, salt []byte, iters int) []byte {
	return pbkdf2sha256(passphrase, salt, iters, keyLen)
}

func secretkey(root []byte, name string) []byte {
	return mac(root, aadSecret+name)
}

// entryid is where a secret lives in the file, derived from its own key
// so that finding it needs no plaintext name. One-way: an id yields
// nothing about the key that produced it.
func entryid(key []byte) []byte {
	return mac(key, labelID)
}

func random(length int) ([]byte, error) {
	out := make([]byte, length)
	if _, err := rand.Read(out); nil != err {
		return nil, fail("no randomness available: " + err.Error())
	}
	return out, nil
}

// --- sealing ---------------------------------------------------------

type sealed struct {
	IV   []byte
	Blob []byte
}

func gcmof(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if nil != err {
		return nil, fail("bad key: " + err.Error())
	}
	return cipher.NewGCM(block)
}

func seal(key []byte, plain []byte, aad string) (*sealed, error) {
	iv, err := random(ivLen)
	if nil != err {
		return nil, err
	}

	gcm, err := gcmof(key)
	if nil != err {
		return nil, err
	}

	return &sealed{IV: iv, Blob: gcm.Seal(nil, iv, plain, []byte(aad))}, nil
}

// unseal returns the plaintext, or a refusal. A GCM tag that fails to
// verify is the only evidence there is, and it cannot tell a wrong
// passphrase from a damaged file, so `what` names the attempt and the
// message admits both.
func unseal(key []byte, box *sealed, aad string, what string) ([]byte, error) {
	if len(box.Blob) < tagLen || ivLen != len(box.IV) {
		return nil, fail(what + ": truncated")
	}

	gcm, err := gcmof(key)
	if nil != err {
		return nil, err
	}

	plain, err := gcm.Open(nil, box.IV, box.Blob, []byte(aad))
	if nil != err {
		return nil, fail(what)
	}

	return plain, nil
}

func jsonof(plain []byte, into any, what string) error {
	if err := json.Unmarshal(plain, into); nil != err {
		return fail("unreadable " + what)
	}
	return nil
}

// --- the file --------------------------------------------------------

type keyRecord struct {
	ID    string
	Salt  []byte
	Iters int
	Ring  *sealed
	Meta  *sealed
}

type entryRecord struct {
	ID    []byte
	Name  *sealed
	Value *sealed
}

type vaultFile struct {
	Keys    []*keyRecord
	Entries []*entryRecord
}

func (file *vaultFile) key(id string) *keyRecord {
	for _, record := range file.Keys {
		if id == record.ID {
			return record
		}
	}
	return nil
}

func (file *vaultFile) entry(id []byte) *entryRecord {
	for _, record := range file.Entries {
		if bytes.Equal(id, record.ID) {
			return record
		}
	}
	return nil
}

// reader is a cursor, so that every length check is in one place: a
// truncated vault is refused rather than read as a short one.
type reader struct {
	bytes []byte
	at    int
	err   error
}

func (read *reader) take64(length uint64) []byte {
	if nil != read.err {
		return nil
	}
	if uint64(len(read.bytes)-read.at) < length {
		read.err = fail("the vault file is truncated")
		return nil
	}
	out := read.bytes[read.at : read.at+int(length)]
	read.at += int(length)
	return out
}

func (read *reader) take(length int) []byte {
	if 0 > length {
		read.err = fail("the vault file is truncated")
		return nil
	}
	return read.take64(uint64(length))
}

func (read *reader) u8() int {
	out := read.take(1)
	if nil == out {
		return 0
	}
	return int(out[0])
}

// u32 is only ever a COUNT, which the caller bounds against the input
// before it allocates. A length goes through u32len instead.
func (read *reader) u32() int {
	out := read.take(4)
	if nil == out {
		return 0
	}
	return int(binary.BigEndian.Uint32(out))
}

func (read *reader) u32len() uint64 {
	out := read.take(4)
	if nil == out {
		return 0
	}
	return uint64(binary.BigEndian.Uint32(out))
}

func (read *reader) small() []byte { return read.take(read.u8()) }
func (read *reader) large() []byte { return read.take64(read.u32len()) }

func (read *reader) sealed() *sealed {
	return &sealed{IV: read.small(), Blob: read.large()}
}

func readfile(raw []byte) (*vaultFile, error) {
	read := &reader{bytes: raw}

	if magic != string(read.take(4)) {
		if nil != read.err {
			return nil, read.err
		}
		return nil, fail("not a vault file")
	}

	version := read.u8()
	if nil != read.err {
		return nil, read.err
	}
	if format != version {
		return nil, fail("unsupported format version: " + strconv.Itoa(version))
	}

	kdf := read.u8()
	ciph := read.u8()
	if nil != read.err {
		return nil, read.err
	}
	if kdfPBKDF2 != kdf || cipherAESGCM != ciph {
		return nil, fail("unsupported kdf or cipher: " + strconv.Itoa(kdf) + "/" + strconv.Itoa(ciph))
	}
	read.u8()

	file := &vaultFile{Keys: []*keyRecord{}, Entries: []*entryRecord{}}

	// A COUNT IS BOUNDED BY WHAT IS LEFT. Each record carries at least a
	// few bytes, so a file claiming four billion of them is damaged; the
	// loop would find that out one truncation at a time, and a caller
	// that preallocated would not.
	keycount := read.u32()
	if len(raw)-read.at < keycount {
		return nil, fail("the vault file is truncated")
	}
	for index := 0; index < keycount && nil == read.err; index++ {
		file.Keys = append(file.Keys, &keyRecord{
			ID:    string(read.small()),
			Salt:  read.small(),
			Iters: read.u32(),
			Ring:  read.sealed(),
			Meta:  read.sealed(),
		})
	}

	entrycount := read.u32()
	if len(raw)-read.at < entrycount {
		return nil, fail("the vault file is truncated")
	}
	for index := 0; index < entrycount && nil == read.err; index++ {
		file.Entries = append(file.Entries, &entryRecord{
			ID:    read.small(),
			Name:  read.sealed(),
			Value: read.sealed(),
		})
	}

	if nil != read.err {
		return nil, read.err
	}
	if read.at != len(raw) {
		return nil, fail("the vault file has trailing bytes")
	}

	return file, nil
}

type writer struct {
	out []byte
}

func (write *writer) u8(value int) { write.out = append(write.out, byte(value)) }

func (write *writer) u32(value int) {
	four := make([]byte, 4)
	binary.BigEndian.PutUint32(four, uint32(value))
	write.out = append(write.out, four...)
}

func (write *writer) small(value []byte) {
	write.u8(len(value))
	write.out = append(write.out, value...)
}

func (write *writer) large(value []byte) {
	write.u32(len(value))
	write.out = append(write.out, value...)
}

func (write *writer) sealed(value *sealed) {
	write.small(value.IV)
	write.large(value.Blob)
}

func writefile(file *vaultFile) []byte {
	write := &writer{out: []byte(magic)}

	write.u8(format)
	write.u8(kdfPBKDF2)
	write.u8(cipherAESGCM)
	write.u8(0)

	write.u32(len(file.Keys))
	for _, record := range file.Keys {
		write.small([]byte(record.ID))
		write.small(record.Salt)
		write.u32(record.Iters)
		write.sealed(record.Ring)
		write.sealed(record.Meta)
	}

	// SORTED BY ID, which is a blinded value: the file therefore records
	// nothing about the order secrets were written in.
	entries := append([]*entryRecord{}, file.Entries...)
	sort.Slice(entries, func(left, right int) bool {
		return 0 > bytes.Compare(entries[left].ID, entries[right].ID)
	})

	write.u32(len(entries))
	for _, record := range entries {
		write.small(record.ID)
		write.sealed(record.Name)
		write.sealed(record.Value)
	}

	return write.out
}
