# VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (ruby/lib/voxgig_sekreto/plugins/minivault.rb)
# Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# A port of typescript/plugins/minivault.ts, which is canonical.
#
# A mini vault: every secret a project owns, encrypted, in ONE FILE.
#
# THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
# every name and mints restricted keys. A restricted key reads the names
# it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
# cryptography rather than a check this code performs. What that does and
# does not protect is set out in DOCS.md under "What the mini vault
# protects".
#
# OpenSSL is ruby's standard library and carries all four primitives, so
# nothing here is hand-rolled (AGENTS.md rule 3).

require 'json'
require 'openssl'

require_relative '../../voxgig_sekreto'

module VoxgigSekreto
  # The mini vault: the format, the keys, the API and the definition.
  module MiniVaultFormat
    # --- the format ----------------------------------------------------
    #
    #   magic       4   'SKMV'
    #   version     1   FORMAT
    #   kdf         1   1 = PBKDF2-HMAC-SHA256
    #   cipher      1   1 = AES-256-GCM
    #   reserved    1   0
    #   keycount    4   uint32
    #   per key:
    #     id        1 + bytes      the key id, PLAINTEXT
    #     salt      1 + bytes
    #     iters     4              PBKDF2 rounds for this key
    #     ring      1 + iv, 4 + bytes    sealed under the passphrase
    #     meta      1 + iv, 4 + bytes    sealed under the vault's meta key
    #   entrycount  4   uint32
    #   per entry:
    #     id        1 + bytes      the blinded lookup id
    #     name      1 + iv, 4 + bytes    sealed under the vault's name key
    #     value     1 + iv, 4 + bytes    sealed under that secret's own key
    #
    # Integers are big-endian, and every length precedes its bytes. A file
    # one port writes is read by every other; `test/fixture` pins that
    # with a committed vault rather than with agreement.

    MAGIC = 'SKMV'
    FORMAT = 1
    KDF_PBKDF2 = 1
    CIPHER_AESGCM = 1

    # AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.
    KEYLEN = 32
    IVLEN = 12
    TAGLEN = 16
    SALTLEN = 16

    # PBKDF2-HMAC-SHA256 rounds when a caller names none.
    ITERATIONS = 210_000

    # The key id a vault gets when a caller names none.
    MASTERKEY = 'master'

    # Additional authenticated data. Every blob is bound to its PLACE in
    # the file, so no ciphertext can be moved.
    AAD_RING = 'skmv1:ring:'
    AAD_META = 'skmv1:meta:'
    AAD_NAME = 'skmv1:name'
    AAD_SECRET = 'skmv1:secret:'

    # Everything a master can reach is derived from the root key, so a
    # rotation is one new random value rather than a re-wrap of each part.
    LABEL_NAMES = 'skmv1:names'
    LABEL_META = 'skmv1:meta'
    LABEL_ID = 'skmv1:id'

    # The largest key id the format can record.
    #
    # `small` writes a length in ONE byte. A longer id wrapped that byte
    # and the writer then appended the whole thing, so every field after
    # it shifted. Checked where an id is ACCEPTED, so the refusal names
    # the id rather than the file.
    IDMAX = 255

    # The export key the vault API is published under, beside the
    # `provider` key every kind publishes.
    VAULT_EXPORT = 'vault'
  end

  module_function

  def minivaultfail(text)
    raise SekretoError, 'sekreto: minivault: ' + text
  end

  def minivaultcheckid(id, what)
    minivaultfail(what) unless id.is_a?(String) && !id.empty?

    if id.bytesize > MiniVaultFormat::IDMAX
      minivaultfail('key id is longer than ' + MiniVaultFormat::IDMAX.to_s +
                    ' bytes: ' + id[0, 32] + '...')
    end
    id
  end

  # --- keys ------------------------------------------------------------

  def minivaulthmac(key, text)
    OpenSSL::HMAC.digest('sha256', key, text.dup.force_encoding('BINARY'))
  end

  # The key-encryption key a passphrase unwraps a ring with.
  def minivaultkek(passphrase, salt, iters)
    OpenSSL::PKCS5.pbkdf2_hmac(passphrase, salt, iters, MiniVaultFormat::KEYLEN,
                               OpenSSL::Digest.new('SHA256'))
  end

  # The key one named secret's value is encrypted with.
  #
  # DERIVED, never stored, for a master: it holds the root key and so
  # reaches every name, including ones written after it was made. A
  # restricted key holds the derived keys it was granted and nothing that
  # produces another.
  def minivaultsecretkey(root, name)
    minivaulthmac(root, MiniVaultFormat::AAD_SECRET + name)
  end

  # Where a secret lives in the file, derived from its own key so that
  # finding it needs no plaintext name.
  def minivaultentryid(key)
    minivaulthmac(key, MiniVaultFormat::LABEL_ID)
  end

  def minivaultrandom(len)
    OpenSSL::Random.random_bytes(len)
  end

  # --- sealing ---------------------------------------------------------

  def minivaultseal(key, plain, aad)
    iv = minivaultrandom(MiniVaultFormat::IVLEN)
    cipher = OpenSSL::Cipher.new('aes-256-gcm')
    cipher.encrypt
    cipher.key = key
    cipher.iv = iv
    cipher.auth_data = aad
    body = cipher.update(plain) + cipher.final
    { 'iv' => iv, 'blob' => body + cipher.auth_tag(MiniVaultFormat::TAGLEN) }
  end

  # The plaintext, or a refusal. A GCM tag that fails to verify is the
  # only evidence there is, and it cannot tell a wrong passphrase from a
  # damaged file, so `what` names the attempt and the message admits both.
  def minivaultunseal(key, sealed, aad, what)
    blob = sealed['blob']
    iv = sealed['iv']

    if blob.bytesize < MiniVaultFormat::TAGLEN || iv.bytesize != MiniVaultFormat::IVLEN
      minivaultfail(what + ': truncated')
    end

    # The WHOLE round-trip is guarded, not only the final block. A nonce
    # or tag of the wrong length makes the setter itself raise.
    begin
      cipher = OpenSSL::Cipher.new('aes-256-gcm')
      cipher.decrypt
      cipher.key = key
      cipher.iv = iv
      cipher.auth_tag = blob[-MiniVaultFormat::TAGLEN..]
      cipher.auth_data = aad
      cipher.update(blob[0...-MiniVaultFormat::TAGLEN]) + cipher.final
    rescue OpenSSL::OpenSSLError, ArgumentError
      minivaultfail(what)
    end
  end

  def minivaultjsonof(plain, what)
    JSON.parse(plain.dup.force_encoding('UTF-8'))
  rescue JSON::ParserError, EncodingError
    minivaultfail('unreadable ' + what)
  end

  def minivaultb64(bytes)
    [bytes].pack('m0')
  end

  def minivaultunb64(text, what)
    minivaultfail('missing ' + what) unless text.is_a?(String)
    text.unpack1('m')
  end

  # --- the file --------------------------------------------------------

  # A cursor, so that every length check is in one place: a truncated
  # vault is refused rather than read as a short one.
  class MiniVaultReader
    def initialize(bytes)
      @bytes = bytes
      @at = 0
    end

    def take(len)
      VoxgigSekreto.minivaultfail('the vault file is truncated') if @bytes.bytesize < @at + len

      out = @bytes.byteslice(@at, len)
      @at += len
      out
    end

    def u8
      take(1).unpack1('C')
    end

    def u32
      take(4).unpack1('N')
    end

    def small
      take(u8)
    end

    def large
      take(u32)
    end

    def magic
      take(4)
    end

    def sealed
      { 'iv' => small, 'blob' => large }
    end

    def done?
      @at == @bytes.bytesize
    end
  end

  def minivaultreadfile(bytes)
    read = MiniVaultReader.new(bytes)

    minivaultfail('not a vault file') if read.magic != MiniVaultFormat::MAGIC

    version = read.u8
    minivaultfail('unsupported format version: ' + version.to_s) if version != MiniVaultFormat::FORMAT

    kdf = read.u8
    cipher = read.u8
    if kdf != MiniVaultFormat::KDF_PBKDF2 || cipher != MiniVaultFormat::CIPHER_AESGCM
      minivaultfail('unsupported kdf or cipher: ' + kdf.to_s + '/' + cipher.to_s)
    end
    read.u8

    keys = []
    read.u32.times do
      id = read.small.force_encoding('UTF-8')
      salt = read.small
      iters = read.u32
      keys.push({ 'id' => id, 'salt' => salt, 'iters' => iters,
                  'ring' => read.sealed, 'meta' => read.sealed })
    end

    entries = []
    read.u32.times do
      entries.push({ 'id' => read.small, 'name' => read.sealed, 'value' => read.sealed })
    end

    minivaultfail('the vault file has trailing bytes') unless read.done?

    { 'keys' => keys, 'entries' => entries }
  end

  def minivaultwritefile(vault)
    out = +''
    out.force_encoding('BINARY')

    u8 = ->(value) { out << [value].pack('C') }
    u32 = ->(value) { out << [value].pack('N') }
    small = lambda { |bytes|
      u8.call(bytes.bytesize)
      out << bytes.dup.force_encoding('BINARY')
    }
    large = lambda { |bytes|
      u32.call(bytes.bytesize)
      out << bytes.dup.force_encoding('BINARY')
    }
    sealed = lambda { |value|
      small.call(value['iv'])
      large.call(value['blob'])
    }

    out << MiniVaultFormat::MAGIC.dup.force_encoding('BINARY')
    u8.call(MiniVaultFormat::FORMAT)
    u8.call(MiniVaultFormat::KDF_PBKDF2)
    u8.call(MiniVaultFormat::CIPHER_AESGCM)
    u8.call(0)

    u32.call(vault['keys'].length)
    vault['keys'].each do |key|
      small.call(key['id'].dup.force_encoding('BINARY'))
      small.call(key['salt'])
      u32.call(key['iters'])
      sealed.call(key['ring'])
      sealed.call(key['meta'])
    end

    # SORTED BY ID, which is a blinded value: the file therefore records
    # nothing about the order secrets were written in.
    entries = vault['entries'].sort_by { |entry| entry['id'].dup.force_encoding('BINARY') }

    u32.call(entries.length)
    entries.each do |entry|
      small.call(entry['id'])
      sealed.call(entry['name'])
      sealed.call(entry['value'])
    end

    out
  end

  # --- creating --------------------------------------------------------

  # A new vault: one master key, no secrets.
  def minivaultnew(keyid, passphrase, iterations)
    root = minivaultrandom(MiniVaultFormat::KEYLEN)
    salt = minivaultrandom(MiniVaultFormat::SALTLEN)

    ring = { 'v' => MiniVaultFormat::FORMAT, 'write' => true, 'root' => minivaultb64(root) }
    meta = { 'v' => MiniVaultFormat::FORMAT, 'master' => true, 'write' => true, 'grants' => [] }

    {
      'keys' => [{
        'id' => keyid,
        'salt' => salt,
        'iters' => iterations,
        'ring' => minivaultseal(minivaultkek(passphrase, salt, iterations),
                                JSON.generate(ring), MiniVaultFormat::AAD_RING + keyid),
        'meta' => minivaultseal(minivaulthmac(root, MiniVaultFormat::LABEL_META),
                                JSON.generate(meta), MiniVaultFormat::AAD_META + keyid)
      }],
      'entries' => []
    }
  end

  # Write a vault file that is not there yet, and REFUSE one that is.
  #
  # Straight to the target under O_CREAT|O_EXCL rather than through a
  # temporary and a rename. `rename` REPLACES its destination, so two
  # processes creating the same vault both succeeded and the second
  # discarded the first one's secrets.
  def minivaultputnew(file, vault)
    File.open(file, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |handle|
      handle.binmode
      handle.write(minivaultwritefile(vault))
    end
  rescue Errno::EEXIST
    minivaultfail('vault file already exists: ' + file)
  rescue SystemCallError => e
    minivaultfail('cannot write ' + file + ': ' + e.message)
  end

  # Is this the same sealed blob, byte for byte?
  def minivaultsameseal(left, right)
    left['iv'] == right['iv'] && left['blob'] == right['blob']
  end

  # --- what a key is ---------------------------------------------------

  # A detached copy, so that what a caller is handed cannot become what
  # this vault believes.
  def minivaultcopyinfo(info)
    {
      'key' => info['key'],
      'master' => info['master'],
      'write' => info['write'],
      'grants' => info['grants'].dup
    }
  end

  # A handle on one vault file, opened as ONE key.
  #
  # Every method answers as that key: `list` shows the names it may read,
  # `get` answers for those and misses on the rest, and the master-only
  # methods refuse for any other key. Nothing is read or derived until the
  # first call that needs the file.
  # THE LOCK EVERY HANDLE ON ONE FILE SHARES.
  #
  # Each MiniVault is its own object, so two handles on one path did not
  # coordinate: both could finish `load` before either saved, and the
  # second `File.rename` then discarded the first one's change while
  # reporting success. Keyed by the ABSOLUTE path, so two handles spelled
  # differently still meet.
  #
  # A guarantee WITHIN one process, which is what DOCS.md promises and
  # what the go port arranges the same way. Two processes still race, and
  # the format's answer to that is the exclusive create and the atomic
  # rename: a reader sees one whole vault or the other, never half of one.
  # Ruby's Mutex is NOT re-entrant, so the five mutating methods must not
  # call one another while holding it - and none of them does: `rotate`
  # reads through `list` and `get`, and every one of them writes through
  # `save`, which takes no lock of its own.
  MINIVAULT_LOCKSMUTEX = Mutex.new
  MINIVAULT_LOCKTABLE = {}

  def self.minivaultlockfor(file)
    key = begin
      File.expand_path(file)
    rescue StandardError
      file
    end

    MINIVAULT_LOCKSMUTEX.synchronize { MINIVAULT_LOCKTABLE[key] ||= Mutex.new }
  end

  class MiniVault
    def initialize(options)
      opts = options || {}
      @file = opts['file']
      # AN EMPTY KEY IS NO KEY, so it means `master`. Ruby's `||` answers
      # for nil alone and an empty String is truthy, where the canonical's
      # `opts.key || MASTERKEY` answers for both. A CLI reaches this with
      # SEKRETO_VAULT_KEY set and empty, which is what an unset shell
      # variable expands to.
      want = opts['key']
      @keyid = want.nil? || want.to_s.empty? ? MiniVaultFormat::MASTERKEY : want
      @passphrase = opts['passphrase']
      @iterations = opts['iterations'] || MiniVaultFormat::ITERATIONS
      @create = opts['create'] == true

      VoxgigSekreto.minivaultfail('a vault needs a file') unless @file.is_a?(String) && !@file.empty?
      unless @passphrase.is_a?(String) && !@passphrase.empty?
        VoxgigSekreto.minivaultfail('a vault needs a passphrase')
      end
      VoxgigSekreto.minivaultcheckid(@keyid, 'a vault needs a key id')

      @opened = nil
    end

    # The file this handle reads.
    def file
      @file
    end

    # The key id this handle opens with.
    def key
      @keyid
    end

    # Derive the key and read the file NOW rather than at first use.
    def open
      VoxgigSekreto.minivaultcopyinfo(load[1]['info'])
    end

    # Forget the derived keys. The next call opens again.
    def close
      @opened = nil
      nil
    end

    # The names this key can read, sorted.
    def list
      vault, opened = load

      if opened['root']
        namekey = VoxgigSekreto.minivaulthmac(opened['root'], MiniVaultFormat::LABEL_NAMES)
        return vault['entries'].map { |entry|
          VoxgigSekreto.minivaultunseal(namekey, entry['name'], MiniVaultFormat::AAD_NAME,
                                        'a secret name is damaged').force_encoding('UTF-8')
        }.sort
      end

      # A restricted key has no name key, so it reports the grants it can
      # actually find: the vault never tells it what else is in there.
      opened['info']['grants'].select { |name|
        !findentry(vault, opened['grants'][name]).nil?
      }.sort
    end

    def has?(name)
      !get(name).nil?
    end

    # The value, or nil when the vault does not hold that name or this key
    # was not granted it.
    def get(name)
      VoxgigSekreto.checkname(name)
      vault, opened = load

      key = keyfor(opened, name)
      # OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as
      # the key that opened it, so a name this key cannot read is a name
      # this store does not hold for this caller.
      return nil if key.nil?

      entry = findentry(vault, key)
      return nil if entry.nil?

      VoxgigSekreto.minivaultunseal(key, entry['value'], MiniVaultFormat::AAD_SECRET + name,
                                    'the value of ' + name + ' is damaged').force_encoding('UTF-8')
    end

    # Write a value. A master writes any name; a restricted key holding
    # `write` overwrites the names it was granted, and creates none.
    def set(name, value)
      # Every write on this file, from any handle in this process,
      # serializes here; see minivaultlockfor.
      VoxgigSekreto.minivaultlockfor(@file).synchronize do
        VoxgigSekreto.checkname(name)
        VoxgigSekreto.minivaultfail('a secret value must be text: ' + name) unless value.is_a?(String)

        vault, opened = load

        unless opened['info']['write']
          VoxgigSekreto.minivaultfail('key ' + opened['info']['key'] + ' is read-only')
        end

        key = keyfor(opened, name)
        if key.nil?
          VoxgigSekreto.minivaultfail('key ' + opened['info']['key'] + ' was not granted ' + name)
        end

        sealedvalue = VoxgigSekreto.minivaultseal(key, value, MiniVaultFormat::AAD_SECRET + name)
        id = VoxgigSekreto.minivaultentryid(key)
        at = vault['entries'].index { |entry| entry['id'] == id }

        if at
          vault['entries'][at] = {
            'id' => vault['entries'][at]['id'],
            'name' => vault['entries'][at]['name'],
            'value' => sealedvalue
          }
        else
          # A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
          # restricted key with `write` updates what it was granted and
          # cannot grow the vault.
          root = rootof(opened, 'creating the secret ' + name)
          vault['entries'].push({
                                  'id' => id,
                                  'name' => VoxgigSekreto.minivaultseal(
                                    VoxgigSekreto.minivaulthmac(root, MiniVaultFormat::LABEL_NAMES),
                                    name, MiniVaultFormat::AAD_NAME
                                  ),
                                  'value' => sealedvalue
                                })
        end

        save(vault)
        nil
      end
    end

    # Drop a name. Master only.
    def remove(name)
      # Every write on this file, from any handle in this process,
      # serializes here; see minivaultlockfor.
      VoxgigSekreto.minivaultlockfor(@file).synchronize do
        VoxgigSekreto.checkname(name)
        vault, opened = load
        root = rootof(opened, 'removing a secret')

        wanted = VoxgigSekreto.minivaultentryid(VoxgigSekreto.minivaultsecretkey(root, name))
        at = vault['entries'].index { |entry| entry['id'] == wanted }
        VoxgigSekreto.minivaultfail('no such secret: ' + name) if at.nil?

        vault['entries'].delete_at(at)
        save(vault)
        nil
      end
    end

    # Every key in the file, with what it may do. Master only.
    def keys
      vault, opened = load
      rootof(opened, 'listing the keys')

      vault['keys'].map do |record|
        meta = metaof(opened, record)
        if meta.nil?
          { 'key' => record['id'], 'master' => false, 'write' => false, 'grants' => [] }
        else
          { 'key' => record['id'], 'master' => meta['master'] == true,
            'write' => meta['write'] == true, 'grants' => (meta['grants'] || []).sort }
        end
      end
    end

    # Mint a restricted key. Master only.
    def grant(spec)
      # Every write on this file, from any handle in this process,
      # serializes here; see minivaultlockfor.
      VoxgigSekreto.minivaultlockfor(@file).synchronize do
        vault, opened = load
        root = rootof(opened, 'granting a key')

        spec ||= {}
        VoxgigSekreto.minivaultcheckid(spec['key'], 'a grant needs a key id')
        unless spec['passphrase'].is_a?(String) && !spec['passphrase'].empty?
          VoxgigSekreto.minivaultfail('a grant needs a passphrase')
        end
        if vault['keys'].any? { |k| k['id'] == spec['key'] }
          VoxgigSekreto.minivaultfail('key already exists: ' + spec['key'])
        end

        names = (spec['names'] || []).sort
        grants = {}
        names.each do |name|
          VoxgigSekreto.checkname(name)
          grants[name] = VoxgigSekreto.minivaultb64(VoxgigSekreto.minivaultsecretkey(root, name))
        end

        write = spec['write'] == true
        vault['keys'].push(sealkey(root, spec['key'], spec['passphrase'],
                                   spec['iterations'] || @iterations,
                                   { 'v' => MiniVaultFormat::FORMAT, 'write' => write,
                                     'grants' => grants },
                                   { 'v' => MiniVaultFormat::FORMAT, 'master' => false,
                                     'write' => write, 'grants' => names }))

        save(vault)
        nil
      end
    end

    # Drop a key. Master only.
    #
    # Anyone who already copied the file keeps whatever that key could
    # read, so revoking bars future reads of the LIVE file and `rotate` is
    # what takes a secret back.
    def revoke(key)
      # Every write on this file, from any handle in this process,
      # serializes here; see minivaultlockfor.
      VoxgigSekreto.minivaultlockfor(@file).synchronize do
        vault, opened = load
        rootof(opened, 'revoking a key')

        VoxgigSekreto.minivaultfail('a key cannot revoke itself: ' + key) if key == opened['info']['key']

        at = vault['keys'].index { |k| k['id'] == key }
        VoxgigSekreto.minivaultfail('no such key: ' + key) if at.nil?

        vault['keys'].delete_at(at)
        save(vault)
        nil
      end
    end

    # A new root key, every value re-encrypted under it, and EVERY OTHER
    # KEY DROPPED. Master only.
    #
    # The other keys go because they must: their rings are sealed under
    # passphrases this process does not have. Re-grant afterwards.
    def rotate
      # Every write on this file, from any handle in this process,
      # serializes here; see minivaultlockfor.
      VoxgigSekreto.minivaultlockfor(@file).synchronize do
        vault, opened = load
        rootof(opened, 'rotating the vault')

        # Read everything out under the old root before anything changes:
        # once the root is replaced the old derived keys are unreachable.
        plain = list.map { |name| [name, get(name)] }

        root = VoxgigSekreto.minivaultrandom(MiniVaultFormat::KEYLEN)
        namekey = VoxgigSekreto.minivaulthmac(root, MiniVaultFormat::LABEL_NAMES)

        entries = plain.map do |name, value|
          key = VoxgigSekreto.minivaultsecretkey(root, name)
          {
            'id' => VoxgigSekreto.minivaultentryid(key),
            'name' => VoxgigSekreto.minivaultseal(namekey, name, MiniVaultFormat::AAD_NAME),
            'value' => VoxgigSekreto.minivaultseal(key, value,
                                                   MiniVaultFormat::AAD_SECRET + name)
          }
        end

        record = vault['keys'].find { |k| k['id'] == @keyid }

        fresh = sealkey(root, @keyid, @passphrase, record['iters'],
                        { 'v' => MiniVaultFormat::FORMAT, 'write' => true,
                          'root' => VoxgigSekreto.minivaultb64(root) },
                        { 'v' => MiniVaultFormat::FORMAT, 'master' => true, 'write' => true,
                          'grants' => [] })

        # SAVE FIRST, adopt second. A handle holding the new root over a
        # file that still holds the old one reads nothing and says the vault
        # is damaged.
        save({ 'keys' => [fresh], 'entries' => entries })

        @opened = {
          'info' => { 'key' => @keyid, 'master' => true, 'write' => true, 'grants' => [] },
          'root' => root,
          'grants' => {},
          'ring' => fresh['ring']
        }
        nil
      end
    end

    private

    def bytes
      File.binread(@file)
    rescue Errno::ENOENT
      # A vault is configured deliberately, with a key. Its absence is a
      # broken deployment and never "no secrets here": answering a miss
      # would send the chain on to a weaker store.
      VoxgigSekreto.minivaultfail('no vault file: ' + @file) unless @create

      VoxgigSekreto.minivaultputnew(@file,
                                    VoxgigSekreto.minivaultnew(@keyid, @passphrase, @iterations))
      File.binread(@file)
    rescue SystemCallError => e
      VoxgigSekreto.minivaultfail('cannot read ' + @file + ': ' + e.message)
    end

    def load
      vault = VoxgigSekreto.minivaultreadfile(bytes)

      record = vault['keys'].find { |k| k['id'] == @keyid }
      if record.nil?
        # REVOKED, or never there. Either way this handle is finished, and
        # dropping what it derived is what stops the next call answering
        # from memory.
        @opened = nil
        VoxgigSekreto.minivaultfail('no such key: ' + @keyid)
      end

      # The file still holds this key, and holds the SAME ring: a key
      # revoked and re-granted under another passphrase is a different key
      # wearing the id, and re-deriving is what refuses it.
      return [vault, @opened] if @opened && VoxgigSekreto.minivaultsameseal(@opened['ring'],
                                                                           record['ring'])

      @opened = nil

      plain = VoxgigSekreto.minivaultunseal(
        VoxgigSekreto.minivaultkek(@passphrase, record['salt'], record['iters']),
        record['ring'], MiniVaultFormat::AAD_RING + @keyid,
        'wrong passphrase for key ' + @keyid + ', or a damaged vault'
      )

      ring = VoxgigSekreto.minivaultjsonof(plain, 'key ring for ' + @keyid)

      grants = {}
      (ring['grants'] || {}).each do |name, key|
        grants[name] = VoxgigSekreto.minivaultunb64(key, 'a granted key')
      end

      @opened = {
        'info' => {
          'key' => @keyid,
          'master' => !ring['root'].nil?,
          'write' => !ring['root'].nil? || ring['write'] == true,
          'grants' => grants.keys.sort
        },
        'root' => ring['root'].nil? ? nil : VoxgigSekreto.minivaultunb64(ring['root'],
                                                                        'the root key'),
        'grants' => grants,
        'ring' => record['ring']
      }

      [vault, @opened]
    end

    def rootof(opened, what)
      if opened['root'].nil?
        VoxgigSekreto.minivaultfail(what + ' needs a master key, and ' +
                                    opened['info']['key'] + ' is restricted')
      end
      opened['root']
    end

    # The key for one name, or nil when this key cannot reach it.
    def keyfor(opened, name)
      return VoxgigSekreto.minivaultsecretkey(opened['root'], name) unless opened['root'].nil?

      opened['grants'][name]
    end

    def findentry(vault, key)
      return nil if key.nil?

      id = VoxgigSekreto.minivaultentryid(key)
      vault['entries'].find { |entry| entry['id'] == id }
    end

    def metaof(opened, record)
      root = rootof(opened, 'reading key metadata')
      what = 'metadata for key ' + record['id']
      VoxgigSekreto.minivaultjsonof(
        VoxgigSekreto.minivaultunseal(
          VoxgigSekreto.minivaulthmac(root, MiniVaultFormat::LABEL_META),
          record['meta'], MiniVaultFormat::AAD_META + record['id'], what
        ), what
      )
    rescue SekretoError
      # A record written under a root key this one has replaced. The key
      # is still in the file and still opens with its own passphrase, so
      # it is reported rather than hidden - with what it can do unknown.
      nil
    end

    def sealkey(root, id, phrase, iters, ring, meta)
      salt = VoxgigSekreto.minivaultrandom(MiniVaultFormat::SALTLEN)
      {
        'id' => id,
        'salt' => salt,
        'iters' => iters,
        'ring' => VoxgigSekreto.minivaultseal(VoxgigSekreto.minivaultkek(phrase, salt, iters),
                                              JSON.generate(ring),
                                              MiniVaultFormat::AAD_RING + id),
        'meta' => VoxgigSekreto.minivaultseal(
          VoxgigSekreto.minivaulthmac(root, MiniVaultFormat::LABEL_META),
          JSON.generate(meta), MiniVaultFormat::AAD_META + id
        )
      }
    end

    # Read, change, and REPLACE - never edit in place.
    #
    # THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
    # anyone can predict, so anyone who can write the vault's directory
    # could put a symlink there and have the next save truncate whatever
    # it pointed at.
    def save(vault)
      temp = @file + '.' + VoxgigSekreto.minivaultrandom(8).unpack1('H*') + '.tmp'

      begin
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |handle|
          handle.binmode
          handle.write(VoxgigSekreto.minivaultwritefile(vault))
        end
        File.rename(temp, @file)
      rescue SystemCallError => e
        begin
          File.unlink(temp)
        rescue SystemCallError
          # The vault is unchanged either way, and the write error is what
          # the caller needs to be told about.
        end
        VoxgigSekreto.minivaultfail('cannot write ' + @file + ': ' + e.message)
      end
      nil
    end
  end

  module_function

  # Open a vault file as one key.
  #
  # The handle is lazy. Nothing is read, and no passphrase is stretched,
  # until a method needs the file.
  def openvault(options)
    MiniVault.new(options)
  end

  # Make a vault file and return a handle on its master key.
  #
  # Refuses a file that is already there: a vault is created once, and
  # overwriting one discards every secret in it.
  def createvault(options)
    opts = options || {}

    minivaultfail('a vault needs a file') unless opts['file'].is_a?(String) && !opts['file'].empty?
    unless opts['passphrase'].is_a?(String) && !opts['passphrase'].empty?
      minivaultfail('a vault needs a passphrase')
    end
    want = opts['key']
    keyid = want.nil? || want.to_s.empty? ? MiniVaultFormat::MASTERKEY : want
    minivaultcheckid(keyid, 'a vault needs a key id')

    # No existence check first: the check and the write would be two
    # steps, and `minivaultputnew` refuses an existing file in ONE.
    minivaultputnew(opts['file'],
                    minivaultnew(keyid, opts['passphrase'],
                                 opts['iterations'] || MiniVaultFormat::ITERATIONS))

    openvault(opts)
  end

  # --- the provider ----------------------------------------------------

  # Read a vault as one store in a chain.
  #
  # The provider is the READ half and nothing more: a chain resolves
  # secrets, and writing one is a deliberate act with an API of its own.
  class MiniVaultProvider
    def initialize(vault)
      @vault = vault
    end

    def lookup(name)
      @vault.get(name)
    end

    def describe
      'minivault:' + @vault.file
    end
  end

  module_function

  def providerof(vault)
    MiniVaultProvider.new(vault)
  end

  # A vault provider from options, for a chain built by hand.
  def minivaultprovider(options)
    providerof(openvault(options))
  end

  # The vault options a provider spec describes.
  def minivaultoptions(spec)
    {
      'file' => spec['file'] || '',
      'key' => spec['vaultkey'],
      'passphrase' => spec['passphrase'] || '',
      'iterations' => spec['iterations'],
      'create' => spec['create'] == true
    }
  end

  # The vault behind a store in a chain, as its programmatic API.
  #
  # With no store named, the unqualified alias answers: one vault in the
  # chain resolves whatever it is called, and two raise rather than
  # picking one.
  def vaultof(secrets, store = nil)
    if store.nil?
      found = secrets.host.exports('minivault/' + MiniVaultFormat::VAULT_EXPORT)
      minivaultfail('no minivault store in this chain') if found.nil?
      return found
    end

    # A NAMED STORE MUST EXIST, and the alias must not stand in for it.
    # `host.exports` falls back to the alias when the exact ref misses, so
    # asking for `minivault` in a chain whose only vault is named `app`
    # used to hand back the `app` vault - and then write to it.
    ref = store == 'minivault' ? 'minivault' : 'minivault$' + store

    minivaultfail('no minivault store named ' + store + ' in this chain') if
      secrets.host.instance(ref).nil?

    secrets.host.exports(ref + '/' + MiniVaultFormat::VAULT_EXPORT)
  end

  module Plugins
    # The `minivault` provider kind, as a voxgig/plugin definition.
    #
    # Written out rather than built by `providerplugin`, because this
    # definition publishes TWO exports: `provider`, the read half every
    # kind publishes, and `vault`, the programmatic API.
    MINIVAULT = {
      'name' => 'minivault',
      'define' => lambda { |inst|
        options = VoxgigSekreto.minivaultoptions(inst.options || {})

        vault = begin
          # `openvault` refuses bad configuration HERE, so a mistyped
          # chain fails at construction. Reaching the FILE is not
          # configuration: the handle is lazy.
          VoxgigSekreto.openvault(options)
        rescue SekretoError => e
          raise VoxgigPlugin::PluginError.new(
            ERROR_CODE, e.message, { 'ref' => inst.ref, 'cause' => e.message }
          )
        end

        inst.export(PROVIDER_EXPORT, VoxgigSekreto.providerof(vault))
        inst.export(MiniVaultFormat::VAULT_EXPORT, vault)
      }
    }.freeze
  end
end
