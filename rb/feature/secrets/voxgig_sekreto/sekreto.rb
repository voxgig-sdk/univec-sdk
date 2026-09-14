# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/sekreto.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# sekreto: one interface for secrets, wherever they live.
#
# A Sekreto is an ordered chain of providers. `get` asks each in turn and
# returns the first hit, so an app can be configured from environment
# variables in development and a vault in production without changing a
# line of its own code.
#
# A port of typescript/src/Sekreto.ts, which is canonical.
#
# THE CORE REQUIRES NO PROVIDER THAT OPENS A SOCKET, SPAWNS A PROCESS OR
# SIGNS A REQUEST. The four built-in kinds - env, memory, dotenv, file -
# read at most a local file; every other kind is a voxgig/plugin
# definition under plugins/, and a chain may name one only if the calling
# project handed it in through `plugins`. See
# docs/design/plugin-providers.md.

require_relative '../voxgig_plugin'

module VoxgigSekreto
  # Anything sekreto refuses to do: a bad name, a missing secret, a
  # provider that could not be reached.
  class SekretoError < StandardError; end

  NAMEPART = /\A[a-z0-9_]+\z/.freeze

  module_function

  # Is this a well-formed secret name?
  def validname(name)
    return false unless name.is_a?(String)
    return false if name.empty?

    name.split('.', -1).all? { |part| NAMEPART.match?(part) }
  end

  def checkname(name)
    raise SekretoError, 'sekreto: invalid name: ' + (name.nil? ? '' : name.to_s) unless validname(name)

    name
  end

  # The environment-variable key for a name: `api.token` -> `API_TOKEN`.
  def envkey(name, prefix = nil)
    checkname(name)
    (prefix || '') + name.split('.', -1).join('_').upcase
  end

  # Where a name lives in a KV vault: `api.token` -> `api` / `token`.
  #
  # A single-segment name has no path of its own, so it becomes a secret of
  # that name with the conventional field `value`.
  def vaultref(name)
    checkname(name)

    parts = name.split('.', -1)

    return { 'path' => parts[0], 'field' => 'value' } if 1 == parts.length

    { 'path' => parts[0...-1].join('/'), 'field' => parts[-1] }
  end

  # A name flattened to one segment: `api.token` -> `api_token` (GCP
  # Secret Manager, `_`) or `api-token` (Azure Key Vault, `-`).
  #
  # Those stores have no path hierarchy and reject dots in ids, so the
  # dots become the store's conventional separator. With `-` as the
  # separator, underscores flatten too: Azure Key Vault's alphabet is
  # letters, digits and hyphens only, and a valid sekreto name like
  # `with_underscore` must still be representable there. (The resulting
  # `.`/`_` collision mirrors the documented envkey behaviour, where
  # both already map to `_`.)
  def flatname(name, sep)
    checkname(name)
    flat = name.split('.', -1).join(sep)
    '-' == sep ? flat.split('_', -1).join('-') : flat
  end

  # The AWS SSM Parameter Store name for a name: dots become the path
  # hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
  # `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`.
  def awsparam(name, prefix = nil)
    checkname(name)

    base = prefix || ''
    base = '/' + base if '' != base && !base.start_with?('/')
    base = base.sub(%r{/\z}, '')

    base + '/' + name.split('.', -1).join('/')
  end

  # Parse `.env` text into a map of raw keys to values.
  #
  # Deliberately small: `KEY=value`, optional `export`, `#` comments on
  # their own line, and single- or double-quoted values (double quotes also
  # unescape \n, \r, \t and \\). A line with no `=` is skipped.
  def parsedotenv(text)
    out = {}

    return out unless text.is_a?(String)

    text.split("\n", -1).each do |rawline|
      line = rawline.sub(/\r\z/, '').strip

      next if line.empty? || line.start_with?('#')

      body = line.start_with?('export ') ? line[7..].strip : line

      eq = body.index('=')
      next if eq.nil? || 0 >= eq

      key = body[0...eq].strip
      value = body[(eq + 1)..].strip

      if 2 <= value.length && value.start_with?('"') && value.end_with?('"')
        value = unescape(value[1...-1])
      elsif 2 <= value.length && value.start_with?("'") && value.end_with?("'")
        value = value[1...-1]
      end

      out[key] = value
    end

    out
  end

  def unescape(text)
    out = +''
    index = 0

    while index < text.length
      if '\\' == text[index] && index + 1 < text.length
        nxt = text[index + 1]
        index += 2
        out << case nxt
               when 'n' then "\n"
               when 'r' then "\r"
               when 't' then "\t"
               when '\\' then '\\'
               when '"' then '"'
               else '\\' + nxt
               end
      else
        out << text[index]
        index += 1
      end
    end

    out
  end

  # Replace known secret values in text with `[redacted]`.
  #
  # Only values of four characters or more are replaced: shorter ones are
  # too likely to appear in ordinary text, and redacting them would make
  # logs unreadable without making them safer.
  def redact(text, values)
    out = text.is_a?(String) ? text : ''

    usable = (values || []).select { |value| value.is_a?(String) && 4 <= value.length }

    # sort_by returns a new array: `values` belongs to the caller (it is
    # @seen when called through Sekreto#redact), and sorting in place
    # would reorder it.
    usable.sort_by { |value| -value.length }.each do |value|
      out = out.split(value, -1).join('[redacted]')
    end

    out
  end

  # Is this optional config value actually set? Both nil and the empty
  # string mean "not given", matching the canonical port's truthiness.
  #
  # In the core because `declare` needs it: `spec['name'] || kind` would
  # take an empty store name, which Ruby counts as truthy and the other
  # ports do not.
  def given(value)
    !value.nil? && '' != value
  end

  # The store name a live provider answers to.
  #
  # `describe` opens with the provider's kind - `hashicorp:...`,
  # `dotenv:...`, plain `env` - so the kind is the natural default, and a
  # custom provider gets a sensible name without implementing anything
  # extra. A spec'd provider's store is its `name` or its `kind`, decided
  # before the provider exists.
  def storename(provider)
    provider.describe.split(':')[0]
  end

  # The secrets facade: a chain of providers plus a cache.
  #
  # Two ways to read. `get` is transparent - it walks the chain and takes the
  # first hit, and the caller never learns which store answered. `getfrom` is
  # directed - it names the store, and only that store is asked.
  class Sekreto
    # `catalog` is the definitions this Sekreto can build; `host` is the
    # voxgig/plugin host every spec'd provider is an instance of. Read
    # them for introspection - `host.list` names each store's ref and
    # status - and nothing on either advances the chain.
    attr_reader :catalog, :host

    def initialize(options = nil)
      opts = options || {}

      # Built-ins first, then the plugins, into one catalog: a plugin that
      # names a built-in kind replaces it, which is how a host substitutes
      # an implementation and never an accident, because the four names
      # are documented.
      plugins = (opts['plugins'] || opts[:plugins] || []).map { |plugin| definition(plugin) }
      @catalog = VoxgigPlugin.make_catalog(BUILTINS + plugins)
      @host = VoxgigPlugin.make_host('catalog' => @catalog)

      # (store, provider) pairs, in chain order. A provider handed in live
      # is backed by no instance; a spec'd one is an instance of its kind
      # on the host.
      @entries = (opts['providers'] || opts[:providers] || []).map do |entry|
        if entry.respond_to?(:lookup)
          [VoxgigSekreto.storename(entry), entry]
        else
          declare(entry)
        end
      end

      cache = opts.key?('cache') ? opts['cache'] : opts[:cache]
      @docache = false != cache

      # A list, not a hash: the store a value came from stays attached, and
      # redaction order does not vary between runs.
      @cache = []

      # Every value ever resolved, for redact. Kept independently of the
      # read cache so that redaction still works when cache is off -
      # otherwise `cache: false` would silently disable redact and leak
      # secrets to logs.
      @seen = []
    end

    # The secret, or a SekretoError if no provider has it.
    def get(name)
      found = try(name)

      raise SekretoError, 'sekreto: unknown secret: ' + name if found.nil?

      found
    end

    # The secret, or nil if no provider has it.
    def try(name)
      resolve('', name, @entries)
    end

    # The secret from one named store, or a SekretoError if that store does
    # not have it.
    def getfrom(store, name)
      found = tryfrom(store, name)

      raise SekretoError, 'sekreto: unknown secret: ' + store + ':' + name if found.nil?

      found
    end

    # The secret from one named store, or nil if that store does not have it.
    #
    # Naming a store that is not in the chain is an error, not a miss: `try`
    # already means "this store may not have it", so it cannot also mean
    # "this store may not exist" without hiding a typo.
    def tryfrom(store, name)
      matching = @entries.select { |entry| entry[0] == store }

      raise SekretoError, 'sekreto: unknown store: ' + store if matching.empty?

      resolve(store, name, matching)
    end

    # Does any provider have this secret?
    def has(name)
      !try(name).nil?
    end

    # Does this named store have this secret?
    def hasin(store, name)
      !tryfrom(store, name).nil?
    end

    # Every named secret at once. Missing ones are an error.
    def all(names)
      names.each_with_object({}) { |name, out| out[name] = get(name) }
    end

    # A description of each provider, in resolution order.
    def sources
      @entries.map { |_store, provider| provider.describe }
    end

    # The name of each store that can be named by `getfrom`, in resolution
    # order and without repeats.
    def stores
      @entries.map { |store, _provider| store }.uniq
    end

    # What a Sekreto shows of itself when something prints it.
    #
    # `p sekreto` and `sekreto.inspect` reach @cache and @seen, which
    # between them hold every value this chain has ever resolved - so one
    # ordinary logging call writes every secret out. `inspect` is also
    # what Rails error pages and most exception reporters call on locals,
    # so this leaks on the path where a process is already in trouble.
    def inspect
      "#<VoxgigSekreto::Sekreto stores=[#{stores.join(', ')}]>"
    end

    # Replace every value this Sekreto has resolved with `[redacted]`.
    #
    # Works whether or not caching is enabled: the redaction list is kept
    # independently of the read cache.
    def redact(text)
      VoxgigSekreto.redact(text, @seen)
    end

    # Drop cached values, so the next `get` asks the providers again.
    def refresh
      @cache.clear
    end

    # Tear the chain down: every plugin instance is deactivated and
    # unloaded, in reverse, releasing whatever a provider acquired at
    # activation. Afterwards there is nothing to read from - `get` reports
    # every secret unknown - and the cache is dropped, though `redact`
    # still knows every value that was ever resolved.
    def close
      @host.close
      @entries = []
      @cache.clear
    end

    private

    # One chain entry, as a plugin instance.
    #
    # The instance is `kind` for a store named after its kind and
    # `kind$store` otherwise - `hashicorp$prod` - so `host.list` reads like
    # the chain. A store name that is already taken gets a numbered tag
    # from the host instead, because two providers MAY share a store name
    # (a directed read walks both) and an instance ref may not.
    def declare(spec)
      spec = stringkeys(spec)
      kind = spec['kind']

      raise SekretoError, unknownkind(kind) unless kind.is_a?(String) && @catalog.has?(kind)

      store = VoxgigSekreto.given(spec['name']) ? spec['name'] : kind

      unless VoxgigPlugin.check_tag(store)
        raise SekretoError, 'sekreto: invalid store name: ' + store.to_s
      end

      ref = store == kind ? kind : VoxgigPlugin.format_ref(kind, store)
      ref = @host.autotag(kind) unless @host.instance(ref).nil?

      begin
        # `load` runs the definition's `define`, which builds the provider
        # from the spec; `activate` takes the instance live. Nothing is
        # contacted by either: a provider opens nothing until its first
        # lookup.
        @host.load(ref, 'options' => spec)
        @host.activate(ref)
      rescue StandardError => e
        raise unwrap(e)
      end

      [store, @host.exports(ref + '/' + PROVIDER_EXPORT)]
    end

    # A spec with symbol keys read as the string keys every definition
    # sees. The spec arrives from JSON in the conformance suite and from
    # a literal hash in an app, and Ruby writes those two differently;
    # `inst.options` must not depend on which.
    #
    # Shallow, as the `kind` switch it replaces was: a nested `auth` has
    # always been read with string keys.
    def stringkeys(spec)
      return spec unless spec.is_a?(Hash)

      spec.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
    end

    # A plugin entry, checked to be a definition before the catalog sees
    # it.
    #
    # `require` hands back `true`, a plugin file defines a MODULE, and the
    # definition inside it is one constant further on - so the three
    # things nearest to hand are all not definitions, and each would fail
    # deep inside voxgig/plugin with a message about a definition name.
    # Refused here instead, naming what to pass.
    def definition(plugin)
      return plugin if plugin.is_a?(Hash)

      what = plugin.is_a?(Module) ? 'the module ' + (plugin.name || plugin.to_s) : plugin.inspect

      raise SekretoError,
            'sekreto: not a plugin definition: ' + what +
            ' - a plugin is a definition, such as VoxgigSekreto::Plugins::HASHICORP,' \
            ' or VoxgigSekreto::Plugins::ALL for every one'
    end

    # The message for a kind the catalog does not hold.
    #
    # A kind sekreto has never heard of is a typo; a kind that exists as a
    # plugin but was not passed in is the split working as designed and
    # telling you what to pass. Collapsing the two was the first thing
    # that made the split confusing to use.
    def unknownkind(kind)
      message = 'sekreto: unknown provider kind: ' + kind.to_s +
                ' (available: ' + @catalog.names.join(', ') + ')'

      return message unless KINDS['plugin'].include?(kind)

      message + ' - ' + kind.to_s +
        ' is a sekreto plugin, not built in: pass it in the plugins option'
    end

    # A SekretoError that crossed the plugin boundary comes back out as
    # itself, byte for byte. Anything else is not sekreto's to rewrite.
    def unwrap(err)
      return err unless err.respond_to?(:code) && ERROR_CODE == err.code

      cause = err.respond_to?(:details) ? err.details['cause'] : nil

      cause.is_a?(String) ? SekretoError.new(cause) : err
    end

    def resolve(store, name, entries)
      VoxgigSekreto.checkname(name)

      if @docache
        hit = @cache.find { |cached| cached[0] == store && cached[1] == name }
        return hit[2] unless hit.nil?
      end

      entries.each do |_store, provider|
        found = provider.lookup(name)

        unless found.nil?
          @cache << [store, name, found] if @docache
          @seen << found
          return found
        end
      end

      nil
    end
  end

  # Make a Sekreto from options.
  def sekreto(options = nil)
    Sekreto.new(options)
  end
end
