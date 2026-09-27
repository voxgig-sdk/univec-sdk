# VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (elixir/plugins/minivault.ex)
# Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The mini vault, as a voxgig/plugin definition.
#
# A port of typescript/plugins/minivault.ts, which is canonical.
#
# A PLUGIN, not a built-in: it needs crypto, which is the line the four
# built-ins stay behind. See docs/design/plugin-providers.md.
#
# THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
# every name and mints restricted keys. A restricted key reads the names
# it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
# cryptography rather than a check this code performs. What that does and
# does not protect is set out in DOCS.md under "What the mini vault
# protects".
#
# Erlang's `:crypto` carries all four primitives, so nothing here is
# hand-rolled (AGENTS.md rule 3).

defmodule Sekreto.Plugins.Minivault do
  @moduledoc """
  A mini vault: every secret a project owns, encrypted, in ONE FILE.

  The format:

      magic       4   'SKMV'
      version     1   FORMAT
      kdf         1   1 = PBKDF2-HMAC-SHA256
      cipher      1   1 = AES-256-GCM
      reserved    1   0
      keycount    4   uint32
      per key:
        id        1 + bytes      the key id, PLAINTEXT
        salt      1 + bytes
        iters     4              PBKDF2 rounds for this key
        ring      1 + iv, 4 + bytes    sealed under the passphrase
        meta      1 + iv, 4 + bytes    sealed under the vault's meta key
      entrycount  4   uint32
      per entry:
        id        1 + bytes      the blinded lookup id
        name      1 + iv, 4 + bytes    sealed under the vault's name key
        value     1 + iv, 4 + bytes    sealed under that secret's own key

  Integers are big-endian, and every length precedes its bytes. A file one
  port writes is read by every other; `test/fixture` pins that with a
  committed vault rather than with agreement.

  THE HANDLE IS A PROCESS. Every other port keeps the derived keys in a
  closure or a field and mutates them; a vault handle here is an Agent,
  because a handle that caches what it derived and a handle that notices a
  revoked key are the same handle, and elixir has no other way to be both.
  """

  alias Sekreto.Error
  alias Sekreto.Json
  alias Sekreto.Providers
  alias Sekreto.ProviderSpec
  alias Voxgig.Plugin.Types
  alias Voxgig.Plugin.Host
  alias Voxgig.Plugin.Inst

  @magic "SKMV"
  @format 1
  @kdf_pbkdf2 1
  @cipher_aesgcm 1

  # AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.
  @keylen 32
  @ivlen 12
  @taglen 16
  @saltlen 16

  @doc "PBKDF2-HMAC-SHA256 rounds when a caller names none."
  def iterations, do: 210_000

  @doc "The key id a vault gets when a caller names none."
  def masterkey, do: "master"

  # Additional authenticated data. Every blob is bound to its PLACE in the
  # file, so no ciphertext can be moved.
  @aad_ring "skmv1:ring:"
  @aad_meta "skmv1:meta:"
  @aad_name "skmv1:name"
  @aad_secret "skmv1:secret:"

  # Everything a master can reach is derived from the root key, so a
  # rotation is one new random value rather than a re-wrap of each part.
  @label_names "skmv1:names"
  @label_meta "skmv1:meta"
  @label_id "skmv1:id"

  # The largest key id the format can record.
  #
  # `small` writes a length in ONE byte. A longer id wrapped that byte and
  # the writer then appended the whole thing, so every field after it
  # shifted. Checked where an id is ACCEPTED, so the refusal names the id
  # rather than the file.
  @idmax 255

  @doc "The export key the vault API is published under, beside `provider`."
  def vault_export, do: "vault"

  defp fail(text) do
    raise Error, message: "sekreto: minivault: " <> text
  end

  # THE LOCK EVERY HANDLE ON ONE FILE SHARES.
  #
  # Each handle is its own map, so two of them on one path did not
  # coordinate: both could finish `load` before either saved, and the
  # second rename then discarded the first one's change while reporting
  # success. Keyed by the ABSOLUTE path, so two handles spelled
  # differently still meet.
  #
  # `:global.trans/2` rather than a mutex, because the BEAM has no shared
  # memory to put one in: processes are the unit here, and this is OTP's
  # own per-key lock over them. Given `[node()]` it is a lock within one
  # node, which is what DOCS.md promises and what the go port arranges
  # with a mutex. Two OS processes still race, and the format's answer to
  # that is the exclusive create and the atomic rename: a reader sees one
  # whole vault or the other, never half of one.
  #
  # It is RE-ENTRANT per process, so a mutating call that ever reached
  # another would wait rather than deadlock; none of them does.
  defp locked(file, body) do
    key =
      case File.cwd() do
        {:ok, _} -> Path.expand(file)
        _ -> file
      end

    :global.trans({{:sekreto_minivault, key}, self()}, body, [node()])
  end

  # The key a caller asked for, or `masterkey()`: an EMPTY key is no key.
  # The canonical's `opts.key || MASTERKEY` answers for both nil and
  # empty, where elixir's `||` answers for nil alone - `""` is truthy
  # here. A CLI reaches this with SEKRETO_VAULT_KEY set and empty, which
  # is what an unset shell variable expands to.
  defp wantkey(nil), do: masterkey()
  defp wantkey(""), do: masterkey()
  defp wantkey(value), do: value

  defp checkid(id, _what) when is_binary(id) and id != "" do
    if byte_size(id) > @idmax do
      fail("key id is longer than #{@idmax} bytes: #{String.slice(id, 0, 32)}...")
    end

    id
  end

  defp checkid(_id, what), do: fail(what)

  # --- keys ------------------------------------------------------------

  defp hmac(key, text), do: :crypto.mac(:hmac, :sha256, key, text)

  # The key-encryption key a passphrase unwraps a ring with.
  defp kek(passphrase, salt, iters) do
    :crypto.pbkdf2_hmac(:sha256, passphrase, salt, iters, @keylen)
  end

  # The key one named secret's value is encrypted with.
  #
  # DERIVED, never stored, for a master: it holds the root key and so
  # reaches every name, including ones written after it was made. A
  # restricted key holds the derived keys it was granted and nothing that
  # produces another.
  defp secretkey(root, name), do: hmac(root, @aad_secret <> name)

  # Where a secret lives in the file, derived from its own key so that
  # finding it needs no plaintext name.
  defp entryid(key), do: hmac(key, @label_id)

  defp random(len), do: :crypto.strong_rand_bytes(len)

  # --- sealing ---------------------------------------------------------

  defp seal(key, plain, aad) do
    iv = random(@ivlen)

    {body, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plain, aad, @taglen, true)

    %{"iv" => iv, "blob" => body <> tag}
  end

  # The plaintext, or a refusal. A GCM tag that fails to verify is the only
  # evidence there is, and it cannot tell a wrong passphrase from a damaged
  # file, so `what` names the attempt and the message admits both.
  defp unseal(key, sealed, aad, what) do
    blob = sealed["blob"]
    iv = sealed["iv"]

    if byte_size(blob) < @taglen or byte_size(iv) != @ivlen do
      fail(what <> ": truncated")
    end

    bodylen = byte_size(blob) - @taglen
    <<body::binary-size(bodylen), tag::binary>> = blob

    # `crypto_one_time_aead` ANSWERS :error rather than raising when the
    # tag does not verify, and raises on a nonce of the wrong length. Both
    # are the same refusal to a caller.
    try do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, body, aad, tag, false) do
        :error -> fail(what)
        plain when is_binary(plain) -> plain
      end
    rescue
      err in Error -> reraise err, __STACKTRACE__
      _ -> fail(what)
    end
  end

  # THE JSON IS TAGGED HERE and plain everywhere else. This port's Json
  # carries `{:obj, pairs}` / `{:str, text}` rather than a bare map, so a
  # ring crosses the boundary twice: `plainof` on the way in, `tagged` on
  # the way out. The bytes are the same either way - the tag is this
  # port's representation, not the format's.
  defp jsonof(plain, what) do
    case Json.parse(plain) do
      {:ok, {:obj, pairs}} -> plainof({:obj, pairs})
      _ -> fail("unreadable " <> what)
    end
  end

  defp plainof({:obj, pairs}), do: Map.new(pairs, fn {key, value} -> {key, plainof(value)} end)
  defp plainof({:arr, entries}), do: Enum.map(entries, &plainof/1)
  defp plainof({:str, text}), do: text
  defp plainof({:num, value}), do: value
  defp plainof({:bool, value}), do: value
  defp plainof(:null), do: nil
  defp plainof(:none), do: nil

  defp tagged(value) when is_map(value) do
    {:obj, Enum.map(value, fn {key, one} -> {key, tagged(one)} end)}
  end

  defp tagged(value) when is_list(value), do: {:arr, Enum.map(value, &tagged/1)}
  defp tagged(value) when is_binary(value), do: {:str, value}
  defp tagged(value) when is_boolean(value), do: {:bool, value}
  defp tagged(value) when is_number(value), do: {:num, value}
  defp tagged(nil), do: :null

  defp stringify(value), do: Json.stringify(tagged(value))

  defp b64(bytes), do: Base.encode64(bytes)

  defp unb64(text, what) when is_binary(text) do
    case Base.decode64(text) do
      {:ok, bytes} -> bytes
      :error -> fail("missing " <> what)
    end
  end

  defp unb64(_text, what), do: fail("missing " <> what)

  # --- the file --------------------------------------------------------

  # A cursor, so that every length check is in one place: a truncated vault
  # is refused rather than read as a short one.
  defp take(bytes, len) when byte_size(bytes) >= len do
    <<out::binary-size(len), rest::binary>> = bytes
    {out, rest}
  end

  defp take(_bytes, _len), do: fail("the vault file is truncated")

  defp u8(bytes) do
    {one, rest} = take(bytes, 1)
    <<value>> = one
    {value, rest}
  end

  defp u32(bytes) do
    {four, rest} = take(bytes, 4)
    <<value::unsigned-big-integer-size(32)>> = four
    {value, rest}
  end

  defp small(bytes) do
    {len, rest} = u8(bytes)
    take(rest, len)
  end

  defp large(bytes) do
    {len, rest} = u32(bytes)
    take(rest, len)
  end

  defp sealed(bytes) do
    {iv, rest} = small(bytes)
    {blob, rest} = large(rest)
    {%{"iv" => iv, "blob" => blob}, rest}
  end

  defp readfile(bytes) do
    {magic, rest} = take(bytes, 4)
    if magic != @magic, do: fail("not a vault file")

    {version, rest} = u8(rest)
    if version != @format, do: fail("unsupported format version: #{version}")

    {kdf, rest} = u8(rest)
    {cipher, rest} = u8(rest)

    if kdf != @kdf_pbkdf2 or cipher != @cipher_aesgcm do
      fail("unsupported kdf or cipher: #{kdf}/#{cipher}")
    end

    {_reserved, rest} = u8(rest)

    {keycount, rest} = u32(rest)
    {keys, rest} = readkeys(rest, keycount, [])

    {entrycount, rest} = u32(rest)
    {entries, rest} = readentries(rest, entrycount, [])

    if rest != "", do: fail("the vault file has trailing bytes")

    %{"keys" => keys, "entries" => entries}
  end

  defp readkeys(bytes, 0, out), do: {Enum.reverse(out), bytes}

  defp readkeys(bytes, left, out) do
    {id, rest} = small(bytes)
    {salt, rest} = small(rest)
    {iters, rest} = u32(rest)
    {ring, rest} = sealed(rest)
    {meta, rest} = sealed(rest)

    readkeys(rest, left - 1, [
      %{"id" => id, "salt" => salt, "iters" => iters, "ring" => ring, "meta" => meta} | out
    ])
  end

  defp readentries(bytes, 0, out), do: {Enum.reverse(out), bytes}

  defp readentries(bytes, left, out) do
    {id, rest} = small(bytes)
    {name, rest} = sealed(rest)
    {value, rest} = sealed(rest)

    readentries(rest, left - 1, [
      %{"id" => id, "name" => name, "value" => value} | out
    ])
  end

  defp putsmall(bytes), do: <<byte_size(bytes)::unsigned-big-integer-size(8)>> <> bytes
  defp putlarge(bytes), do: <<byte_size(bytes)::unsigned-big-integer-size(32)>> <> bytes
  defp putsealed(value), do: putsmall(value["iv"]) <> putlarge(value["blob"])
  defp putu32(value), do: <<value::unsigned-big-integer-size(32)>>

  defp writefile(vault) do
    head =
      @magic <>
        <<@format::8, @kdf_pbkdf2::8, @cipher_aesgcm::8, 0::8>> <>
        putu32(length(vault["keys"]))

    keys =
      Enum.map_join(vault["keys"], "", fn key ->
        putsmall(key["id"]) <>
          putsmall(key["salt"]) <>
          putu32(key["iters"]) <>
          putsealed(key["ring"]) <> putsealed(key["meta"])
      end)

    # SORTED BY ID, which is a blinded value: the file therefore records
    # nothing about the order secrets were written in.
    entries = Enum.sort_by(vault["entries"], & &1["id"], :asc)

    body =
      Enum.map_join(entries, "", fn entry ->
        putsmall(entry["id"]) <> putsealed(entry["name"]) <> putsealed(entry["value"])
      end)

    head <> keys <> putu32(length(entries)) <> body
  end

  # --- creating --------------------------------------------------------

  # A new vault: one master key, no secrets.
  defp newvault(keyid, passphrase, iters) do
    root = random(@keylen)
    salt = random(@saltlen)

    ring = %{"v" => @format, "write" => true, "root" => b64(root)}
    meta = %{"v" => @format, "master" => true, "write" => true, "grants" => []}

    %{
      "keys" => [
        %{
          "id" => keyid,
          "salt" => salt,
          "iters" => iters,
          "ring" =>
            seal(kek(passphrase, salt, iters), stringify(ring), @aad_ring <> keyid),
          "meta" => seal(hmac(root, @label_meta), stringify(meta), @aad_meta <> keyid)
        }
      ],
      "entries" => []
    }
  end

  # Write a vault file that is not there yet, and REFUSE one that is.
  #
  # `:exclusive` is O_CREAT|O_EXCL, rather than a temporary and a rename.
  # A rename REPLACES its destination, so two processes creating the same
  # vault both succeeded and the second discarded the first one's secrets.
  defp putnew(file, vault) do
    case File.open(file, [:write, :binary, :exclusive]) do
      {:ok, handle} ->
        IO.binwrite(handle, writefile(vault))
        File.close(handle)
        File.chmod(file, 0o600)
        :ok

      {:error, :eexist} ->
        fail("vault file already exists: " <> file)

      {:error, why} ->
        fail("cannot write " <> file <> ": " <> to_string(:file.format_error(why)))
    end
  end

  # --- the handle ------------------------------------------------------

  @doc """
  Open a vault file as one key.

  The handle is lazy. Nothing is read, and no passphrase is stretched,
  until a call needs the file.
  """
  def openvault(options) do
    opts = options || %{}
    file = opts["file"]
    passphrase = opts["passphrase"]

    if not is_binary(file) or file == "", do: fail("a vault needs a file")
    if not is_binary(passphrase) or passphrase == "", do: fail("a vault needs a passphrase")

    keyid = checkid(wantkey(opts["key"]), "a vault needs a key id")

    {:ok, agent} = Agent.start_link(fn -> nil end)

    %{
      file: file,
      key: keyid,
      passphrase: passphrase,
      iterations: opts["iterations"] || iterations(),
      create: opts["create"] == true,
      agent: agent
    }
  end

  @doc """
  Make a vault file and return a handle on its master key.

  Refuses a file that is already there: a vault is created once, and
  overwriting one discards every secret in it.
  """
  def createvault(options) do
    opts = options || %{}
    file = opts["file"]
    passphrase = opts["passphrase"]

    if not is_binary(file) or file == "", do: fail("a vault needs a file")
    if not is_binary(passphrase) or passphrase == "", do: fail("a vault needs a passphrase")

    keyid = checkid(wantkey(opts["key"]), "a vault needs a key id")

    # No existence check first: the check and the write would be two
    # steps, and `putnew` refuses an existing file in ONE.
    putnew(file, newvault(keyid, passphrase, opts["iterations"] || iterations()))

    openvault(opts)
  end

  @doc "The file this handle reads."
  def file(vault), do: vault.file

  @doc "The key id this handle opens with."
  def key(vault), do: vault.key

  @doc """
  Derive the key and read the file NOW rather than at first use.

  A COPY, so that what a caller is handed cannot become what this vault
  believes: `open(v) |> Map.put("write", true)` changes a map nobody reads.
  """
  def open(vault) do
    {_file, opened} = load(vault)

    %{
      "key" => opened["info"]["key"],
      "master" => opened["info"]["master"],
      "write" => opened["info"]["write"],
      "grants" => opened["info"]["grants"]
    }
  end

  @doc "Forget the derived keys. The next call opens again."
  def close(vault) do
    Agent.update(vault.agent, fn _ -> nil end)
    :ok
  end

  @doc "The names this key can read, sorted."
  def list(vault) do
    {file, opened} = load(vault)

    if opened["root"] do
      namekey = hmac(opened["root"], @label_names)

      file["entries"]
      |> Enum.map(&unseal(namekey, &1["name"], @aad_name, "a secret name is damaged"))
      |> Enum.sort()
    else
      # A restricted key has no name key, so it reports the grants it can
      # actually find: the vault never tells it what else is in there.
      opened["info"]["grants"]
      |> Enum.filter(&(nil != findentry(file, opened["grants"][&1])))
      |> Enum.sort()
    end
  end

  @doc "Does this key hold a value for `name`?"
  def has?(vault, name), do: nil != get(vault, name)

  @doc """
  The value, or nil when the vault does not hold that name or this key was
  not granted it.
  """
  def get(vault, name) do
    Sekreto.checkname(name)
    {file, opened} = load(vault)

    case keyfor(opened, name) do
      # OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as the
      # key that opened it, so a name this key cannot read is a name this
      # store does not hold for this caller.
      nil ->
        nil

      key ->
        case findentry(file, key) do
          nil ->
            nil

          entry ->
            unseal(key, entry["value"], @aad_secret <> name,
              "the value of " <> name <> " is damaged")
        end
    end
  end

  @doc """
  Write a value. A master writes any name; a restricted key holding
  `write` overwrites the names it was granted, and creates none.
  """
  def set(vault, name, value) do
    # Every write on this file, from any handle in this process,
    # serializes here; see locked.
    locked(vault.file, fn ->
        Sekreto.checkname(name)
        if not is_binary(value), do: fail("a secret value must be text: " <> name)

        {file, opened} = load(vault)

        if not opened["info"]["write"] do
          fail("key " <> opened["info"]["key"] <> " is read-only")
        end

        key = keyfor(opened, name)

        if nil == key do
          fail("key " <> opened["info"]["key"] <> " was not granted " <> name)
        end

        sealedvalue = seal(key, value, @aad_secret <> name)
        id = entryid(key)

        entries =
          if Enum.any?(file["entries"], &(&1["id"] == id)) do
            Enum.map(file["entries"], fn entry ->
              if entry["id"] == id, do: Map.put(entry, "value", sealedvalue), else: entry
            end)
          else
            # A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
            # restricted key with `write` updates what it was granted and
            # cannot grow the vault.
            root = rootof(opened, "creating the secret " <> name)

            file["entries"] ++
              [
                %{
                  "id" => id,
                  "name" => seal(hmac(root, @label_names), name, @aad_name),
                  "value" => sealedvalue
                }
              ]
          end

        save(vault, Map.put(file, "entries", entries))
    end)
  end

  @doc "Drop a name. Master only."
  def remove(vault, name) do
    # Every write on this file, from any handle in this process,
    # serializes here; see locked.
    locked(vault.file, fn ->
        Sekreto.checkname(name)
        {file, opened} = load(vault)
        root = rootof(opened, "removing a secret")

        wanted = entryid(secretkey(root, name))

        if not Enum.any?(file["entries"], &(&1["id"] == wanted)) do
          fail("no such secret: " <> name)
        end

        save(vault, Map.put(file, "entries", Enum.reject(file["entries"], &(&1["id"] == wanted))))
    end)
  end

  @doc "Every key in the file, with what it may do. Master only."
  def keys(vault) do
    {file, opened} = load(vault)
    rootof(opened, "listing the keys")

    Enum.map(file["keys"], fn record ->
      case metaof(opened, record) do
        nil ->
          %{"key" => record["id"], "master" => false, "write" => false, "grants" => []}

        meta ->
          %{
            "key" => record["id"],
            "master" => meta["master"] == true,
            "write" => meta["write"] == true,
            "grants" => Enum.sort(meta["grants"] || [])
          }
      end
    end)
  end

  @doc "Mint a restricted key. Master only."
  def grant(vault, spec) do
    # Every write on this file, from any handle in this process,
    # serializes here; see locked.
    locked(vault.file, fn ->
        {file, opened} = load(vault)
        root = rootof(opened, "granting a key")

        want = spec || %{}
        id = checkid(want["key"], "a grant needs a key id")
        phrase = want["passphrase"]

        if not is_binary(phrase) or phrase == "", do: fail("a grant needs a passphrase")
        if Enum.any?(file["keys"], &(&1["id"] == id)), do: fail("key already exists: " <> id)

        names = Enum.sort(want["names"] || [])

        grants =
          Enum.reduce(names, %{}, fn name, out ->
            Sekreto.checkname(name)
            Map.put(out, name, b64(secretkey(root, name)))
          end)

        write = want["write"] == true

        record =
          sealkey(root, id, phrase, want["iterations"] || vault.iterations,
            %{"v" => @format, "write" => write, "grants" => grants},
            %{"v" => @format, "master" => false, "write" => write, "grants" => names})

        save(vault, Map.put(file, "keys", file["keys"] ++ [record]))
    end)
  end

  @doc """
  Drop a key. Master only.

  Anyone who already copied the file keeps whatever that key could read,
  so revoking bars future reads of the LIVE file and `rotate` is what
  takes a secret back.
  """
  def revoke(vault, key) do
    # Every write on this file, from any handle in this process,
    # serializes here; see locked.
    locked(vault.file, fn ->
        {file, opened} = load(vault)
        rootof(opened, "revoking a key")

        if key == opened["info"]["key"], do: fail("a key cannot revoke itself: " <> key)
        if not Enum.any?(file["keys"], &(&1["id"] == key)), do: fail("no such key: " <> key)

        save(vault, Map.put(file, "keys", Enum.reject(file["keys"], &(&1["id"] == key))))
    end)
  end

  @doc """
  A new root key, every value re-encrypted under it, and EVERY OTHER KEY
  DROPPED. Master only.

  The other keys go because they must: their rings are sealed under
  passphrases this process does not have. Re-grant afterwards.
  """
  def rotate(vault) do
    # Every write on this file, from any handle in this process,
    # serializes here; see locked.
    locked(vault.file, fn ->
        {file, opened} = load(vault)
        rootof(opened, "rotating the vault")

        # Read everything out under the old root before anything changes: once
        # the root is replaced the old derived keys are unreachable.
        plain = Enum.map(list(vault), fn name -> {name, get(vault, name)} end)

        root = random(@keylen)
        namekey = hmac(root, @label_names)

        entries =
          Enum.map(plain, fn {name, value} ->
            key = secretkey(root, name)

            %{
              "id" => entryid(key),
              "name" => seal(namekey, name, @aad_name),
              "value" => seal(key, value, @aad_secret <> name)
            }
          end)

        iters =
          case Enum.find(file["keys"], &(&1["id"] == vault.key)) do
            nil -> vault.iterations
            record -> record["iters"]
          end

        fresh =
          sealkey(root, vault.key, vault.passphrase, iters,
            %{"v" => @format, "write" => true, "root" => b64(root)},
            %{"v" => @format, "master" => true, "write" => true, "grants" => []})

        # SAVE FIRST, adopt second. A handle holding the new root over a file
        # that still holds the old one reads nothing and says the vault is
        # damaged.
        :ok = write(vault, %{"keys" => [fresh], "entries" => entries})

        Agent.update(vault.agent, fn _ ->
          %{
            "info" => %{
              "key" => vault.key,
              "master" => true,
              "write" => true,
              "grants" => []
            },
            "root" => root,
            "grants" => %{},
            "ring" => fresh["ring"]
          }
        end)

        :ok
    end)
  end

  # --- the inside ------------------------------------------------------

  defp bytes(vault) do
    case File.read(vault.file) do
      {:ok, raw} ->
        raw

      {:error, :enoent} ->
        # A vault is configured deliberately, with a key. Its absence is a
        # broken deployment and never "no secrets here": answering a miss
        # would send the chain on to a weaker store.
        if not vault.create, do: fail("no vault file: " <> vault.file)

        putnew(vault.file, newvault(vault.key, vault.passphrase, vault.iterations))
        File.read!(vault.file)

      {:error, why} ->
        fail("cannot read " <> vault.file <> ": " <> to_string(:file.format_error(why)))
    end
  end

  defp load(vault) do
    file = readfile(bytes(vault))
    record = Enum.find(file["keys"], &(&1["id"] == vault.key))

    if nil == record do
      # REVOKED, or never there. Either way this handle is finished, and
      # dropping what it derived is what stops the next call answering from
      # memory.
      Agent.update(vault.agent, fn _ -> nil end)
      fail("no such key: " <> vault.key)
    end

    held = Agent.get(vault.agent, & &1)

    # The file still holds this key, and holds the SAME ring: a key revoked
    # and re-granted under another passphrase is a different key wearing
    # the id, and re-deriving is what refuses it.
    if held && held["ring"] == record["ring"] do
      {file, held}
    else
      Agent.update(vault.agent, fn _ -> nil end)

      plain =
        unseal(
          kek(vault.passphrase, record["salt"], record["iters"]),
          record["ring"],
          @aad_ring <> vault.key,
          "wrong passphrase for key " <> vault.key <> ", or a damaged vault"
        )

      ring = jsonof(plain, "key ring for " <> vault.key)

      grants =
        Enum.reduce(ring["grants"] || %{}, %{}, fn {name, key}, out ->
          Map.put(out, name, unb64(key, "a granted key"))
        end)

      root = ring["root"]

      opened = %{
        "info" => %{
          "key" => vault.key,
          "master" => nil != root,
          "write" => nil != root or ring["write"] == true,
          "grants" => Enum.sort(Map.keys(grants))
        },
        "root" => if(nil == root, do: nil, else: unb64(root, "the root key")),
        "grants" => grants,
        "ring" => record["ring"]
      }

      Agent.update(vault.agent, fn _ -> opened end)
      {file, opened}
    end
  end

  defp rootof(opened, what) do
    if nil == opened["root"] do
      fail(what <> " needs a master key, and " <> opened["info"]["key"] <> " is restricted")
    end

    opened["root"]
  end

  # The key for one name, or nil when this key cannot reach it.
  defp keyfor(opened, name) do
    if opened["root"] do
      secretkey(opened["root"], name)
    else
      opened["grants"][name]
    end
  end

  defp findentry(_file, nil), do: nil

  defp findentry(file, key) do
    id = entryid(key)
    Enum.find(file["entries"], &(&1["id"] == id))
  end

  defp metaof(opened, record) do
    root = rootof(opened, "reading key metadata")
    what = "metadata for key " <> record["id"]

    jsonof(
      unseal(hmac(root, @label_meta), record["meta"], @aad_meta <> record["id"], what),
      what
    )
  rescue
    # A record written under a root key this one has replaced. The key is
    # still in the file and still opens with its own passphrase, so it is
    # reported rather than hidden - with what it can do unknown.
    Error -> nil
  end

  defp sealkey(root, id, phrase, iters, ring, meta) do
    salt = random(@saltlen)

    %{
      "id" => id,
      "salt" => salt,
      "iters" => iters,
      "ring" => seal(kek(phrase, salt, iters), stringify(ring), @aad_ring <> id),
      "meta" => seal(hmac(root, @label_meta), stringify(meta), @aad_meta <> id)
    }
  end

  defp save(vault, file) do
    :ok = write(vault, file)
    # The next call re-reads and re-checks the ring, which is what makes a
    # revoked key stop answering.
    :ok
  end

  # Read, change, and REPLACE - never edit in place.
  #
  # THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
  # anyone can predict, so anyone who can write the vault's directory could
  # put a symlink there and have the next save truncate whatever it pointed
  # at.
  defp write(vault, file) do
    temp = vault.file <> "." <> Base.encode16(random(8), case: :lower) <> ".tmp"

    case File.open(temp, [:write, :binary, :exclusive]) do
      {:ok, handle} ->
        IO.binwrite(handle, writefile(file))
        File.close(handle)
        File.chmod(temp, 0o600)

        case File.rename(temp, vault.file) do
          :ok ->
            :ok

          {:error, why} ->
            File.rm(temp)
            fail("cannot write " <> vault.file <> ": " <> to_string(:file.format_error(why)))
        end

      {:error, why} ->
        fail("cannot write " <> vault.file <> ": " <> to_string(:file.format_error(why)))
    end
  end

  # --- the provider ----------------------------------------------------

  @doc """
  Read a vault as one store in a chain.

  The provider is the READ half and nothing more: a chain resolves
  secrets, and writing one is a deliberate act with an API of its own.
  """
  def providerof(vault) do
    %{
      lookup: fn name -> get(vault, name) end,
      describe: fn -> "minivault:" <> vault.file end
    }
  end

  @doc "A vault provider from options, for a chain built by hand."
  def minivaultprovider(options), do: providerof(openvault(options))

  # The options arrive as a `ProviderSpec` STRUCT here, not as a map: this
  # port types the chain rather than passing dictionaries around, so a
  # field is read by name and a typo does not compile.
  defp vaultoptions(%ProviderSpec{} = spec) do
    %{
      "file" => blankor(spec.file, ""),
      "key" => blankor(spec.vaultkey, nil),
      "passphrase" => blankor(spec.passphrase, ""),
      "iterations" => spec.iterations,
      "create" => spec.create == true
    }
  end

  defp blankor(value, fallback) do
    if is_binary(value) and value != "", do: value, else: fallback
  end

  @doc """
  The `minivault` provider kind, as a voxgig/plugin definition.

  Written out rather than built by `providerplugin`, because this
  definition publishes TWO exports: `provider`, the read half every kind
  publishes, and `vault`, the programmatic API.
  """
  def minivault do
    %{
      "name" => "minivault",
      "define" => fn inst ->
        options = vaultoptions(Inst.options(inst))

        vault =
          try do
            # `openvault` refuses bad configuration HERE, so a mistyped
            # chain fails at construction. Reaching the FILE is not
            # configuration: the handle is lazy.
            openvault(options)
          rescue
            err in Error ->
              Types.fail(Providers.error_code(), Exception.message(err), %{
                "ref" => Inst.ref(inst),
                "cause" => Exception.message(err)
              })
          end

        Inst.export(inst, Providers.provider_export(), providerof(vault))
        Inst.export(inst, vault_export(), vault)
      end
    }
  end

  @doc """
  The vault behind a store in a chain, as its programmatic API.

  With no store named, the unqualified alias answers: one vault in the
  chain resolves whatever it is called, and two raise rather than picking
  one.
  """
  def vaultof(secrets), do: vaultof(secrets, nil)

  def vaultof(secrets, nil) do
    case Host.exports(secrets.host, "minivault/" <> vault_export()) do
      nil -> fail("no minivault store in this chain")
      found -> found
    end
  end

  def vaultof(secrets, store) do
    # A NAMED STORE MUST EXIST, and the alias must not stand in for it.
    # `host.exports` falls back to the alias when the exact ref misses, so
    # asking for `minivault` in a chain whose only vault is named `app`
    # used to hand back the `app` vault - and then write to it.
    ref = if store == "minivault", do: "minivault", else: "minivault$" <> store

    if nil == Host.instance(secrets.host, ref) do
      fail("no minivault store named " <> store <> " in this chain")
    end

    Host.exports(secrets.host, ref <> "/" <> vault_export())
  end
end
