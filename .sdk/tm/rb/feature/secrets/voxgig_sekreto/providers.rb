# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/providers.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# What a provider is, how a provider kind becomes a voxgig/plugin
# definition - and the four BUILT-IN kinds.
#
# A provider answers one question: "do you have this secret?" It returns
# the value, or nil to mean "ask the next one". Nothing else about a
# provider is visible to the caller - which is the point: an app reads
# `api.token` and never learns whether it came from the environment, a
# .env file, HashiCorp Vault or a boru vault.
#
# Two failure shapes, and they are never interchangeable. A store that
# does not hold the secret is a MISS (nil) - the chain carries on. A
# store that could not answer - bad credentials, unreachable host,
# missing configuration - is an ERROR: falling through there would
# quietly reach for a weaker store.
#
# THIS FILE REQUIRES NO net/http, NO openssl AND NO open3. What makes a
# kind built in is that it needs nothing of the platform beyond reading a
# local file; every kind that opens a socket, signs a request or spawns a
# process is a plugin under plugins/, its own file, required only by a
# program that names it (docs/design/plugin-providers.md).
#
# A port of typescript/src/provider/support.ts and
# typescript/src/provider/builtin.ts, which are canonical.

require_relative 'sekreto'

module VoxgigSekreto
  # Environment variables: `api.token` from `API_TOKEN`.
  class EnvProvider
    def initialize(prefix = nil, source = nil)
      @prefix = prefix
      @source = source || ENV
    end

    def lookup(name)
      value = @source[VoxgigSekreto.envkey(name, @prefix)]
      value.nil? ? nil : value.to_s
    end

    def describe
      'env' + (@prefix ? ':' + @prefix : '')
    end
  end

  # A `.env` file, read once, keyed exactly like the environment.
  class DotenvProvider
    def initialize(file, prefix = nil)
      @file = file
      @prefix = prefix
      @values = nil
    end

    def load
      if @values.nil?
        @values = begin
          VoxgigSekreto.parsedotenv(File.read(@file))
        rescue Errno::ENOENT, Errno::ENOTDIR
          # An absent file - or an absent directory - means "no secrets
          # here", exactly like FileProvider. Anything else (permission
          # denied, an unreadable mount) is a store that could not answer,
          # and swallowing it would fall through to a weaker store.
          {}
        rescue StandardError => e
          raise SekretoError, 'sekreto: dotenv provider cannot read ' + @file + ': ' + e.message
        end
      end
      @values
    end

    def lookup(name)
      load[VoxgigSekreto.envkey(name, @prefix)]
    end

    def describe
      'dotenv:' + @file
    end
  end

  # Literal values, keyed like environment variables. The spec uses this to
  # test chain behaviour without touching the outside world.
  class MemoryProvider
    def initialize(values, prefix = nil)
      @values = values || {}
      @prefix = prefix
    end

    def lookup(name)
      @values[VoxgigSekreto.envkey(name, @prefix)]
    end

    def describe
      'memory' + (@prefix ? ':' + @prefix : '')
    end
  end

  # A directory of one-secret-per-file entries, keyed like the
  # environment: `api.token` reads `<dir>/API_TOKEN`.
  #
  # This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
  # secret, and a systemd credentials directory, so those all work with no
  # further configuration. One trailing newline is stripped - tools that
  # write these files disagree about it, and a newline is never part of a
  # secret on purpose.
  class FileProvider
    def initialize(dir, prefix = nil)
      @dir = dir
      @prefix = prefix
    end

    def lookup(name)
      file = File.join(@dir, VoxgigSekreto.envkey(name, @prefix))

      text = begin
        File.read(file)
      rescue Errno::ENOENT, Errno::ENOTDIR
        # An absent file - or an absent directory - means "no secrets
        # here", exactly like a missing .env. Anything else (permission
        # denied, an unreadable mount) is a store that could not answer.
        return nil
      rescue StandardError => e
        raise SekretoError, 'sekreto: file provider cannot read ' + file + ': ' + e.message
      end

      text.sub(/\r?\n\z/, '')
    end

    def describe
      'file:' + @dir
    end
  end

  # --- providers as voxgig/plugin definitions ----------------------------

  # The export key under which a provider definition publishes the
  # provider it built. `Sekreto` reads `<ref>/provider` off the host.
  PROVIDER_EXPORT = 'provider'

  # The voxgig/plugin error code a SekretoError travels under when it is
  # raised inside a definition's `define`.
  #
  # plugin wraps a code-less error raised by a callback as
  # `plugin_define_failed`, and keeps an error that already carries a
  # code. A provider that refuses its own configuration - `kv: 3`, a
  # missing project - raises a SekretoError, and that message is pinned
  # by the spec byte for byte, so it must come back out of the host
  # exactly as it went in. `providerplugin` gives it this code on the way
  # in; `Sekreto` turns it back into a SekretoError on the way out.
  ERROR_CODE = 'sekreto_error'

  module_function

  # A provider kind, as a voxgig/plugin definition.
  #
  # This is the whole bridge between the two libraries. The definition's
  # `name` is the `kind` a spec names; its `define` reads the spec as
  # `inst.options`, builds the provider with `make`, and exports it.
  # Nothing runs at `activate`: a provider opens nothing until its first
  # lookup, so there is nothing to capture - a provider that does hold a
  # resource acquires it there and lets the instance scope unwind it.
  #
  # Every built-in and every plugin is made this way, so a custom
  # provider kind is one call:
  #
  #     providerplugin('mystore', ->(spec) { MyStore.new(spec['addr']) })
  def providerplugin(kind, make)
    {
      'name' => kind,
      'define' => lambda { |inst|
        provider = begin
          make.call(inst.options || {})
        rescue SekretoError => e
          raise VoxgigPlugin::PluginError.new(
            ERROR_CODE, e.message, { 'ref' => inst.ref, 'cause' => e.message }
          )
        end

        inst.export(PROVIDER_EXPORT, provider)
      }
    }
  end

  # The four built-in provider kinds - the same four in every port. What
  # makes a kind built in is that it reads at most a local file: no
  # socket, no TLS, no crypto, no child process.
  BUILTINS = [
    providerplugin('env', ->(spec) { EnvProvider.new(spec['prefix']) }),
    providerplugin('memory', lambda { |spec|
      MemoryProvider.new(spec['values'] || {}, spec['prefix'])
    }),
    providerplugin('dotenv', lambda { |spec|
      DotenvProvider.new(spec['file'] || '.env', spec['prefix'])
    }),
    providerplugin('file', ->(spec) { FileProvider.new(spec['dir'] || '', spec['prefix']) })
  ].freeze

  # Every kind this library ships, built in or as a plugin, so that a kind
  # sekreto has never heard of can be told from one that was not passed in.
  KINDS = {
    'builtin' => %w[env memory dotenv file].freeze,
    'plugin' => %w[
      hashicorp boru awssecrets awsparams gcpsecrets azuresecrets
      onepassword doppler infisical secretspec
    ].freeze
  }.freeze
end
