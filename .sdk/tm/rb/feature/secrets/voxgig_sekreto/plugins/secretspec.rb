# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/secretspec.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The secretspec plugin: SecretSpec, read through its own CLI. Needs a
# child process. A port of typescript/plugins/secretspec.ts, which is
# canonical.

require 'open3'

require_relative '../../voxgig_sekreto'

module VoxgigSekreto
  module_function

  # Does this SecretSpec failure mean "no such secret" rather than "I
  # could not answer"?
  #
  # SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
  # not declare and one declared with no value, and both are misses: this
  # store does not hold it, so the chain carries on.
  #
  # MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
  # `Provider backend 'keyring' not found`, which is a store that could
  # not answer at all - and reading that as a miss is the worst failure
  # this library has, because the chain then falls through to a weaker
  # store without saying so. The key is required to appear, so the two
  # cannot be confused.
  def secretspecmiss(why, key)
    why.include?("Secret '" + key + "' not found")
  end

  # SecretSpec (https://secretspec.dev).
  #
  # SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
  # project needs - plus a chain of its own backends to satisfy them from.
  # That makes it the same shape as sekreto one level down, and the reason
  # to support it is the same reason sekreto exists: a project that has
  # already declared its secrets there should not have to declare them
  # again here.
  #
  # Read through its CLI, as boru is, because that is the interface it
  # offers a program in another language: `secretspec get API_TOKEN`
  # prints the value on stdout and nothing else. A sekreto name maps to a
  # SecretSpec key exactly as it maps to an environment variable -
  # `api.token` is `API_TOKEN` - which is the convention SecretSpec's own
  # examples use.
  #
  # `backend` selects one of SecretSpec's backends (`--provider`, e.g.
  # `keyring` or `dotenv://.env`) and is called `backend` here only
  # because `provider` already means something else in this library.
  #
  # A reason is required, not optional: SecretSpec records every read in
  # an audit log and refuses to read at all without one. sekreto sends
  # `sekreto` unless told otherwise, so the audit trail says which tool
  # asked.
  class SecretspecProvider
    def initialize(command = nil, file = nil, profile = nil,
                   backend = nil, reason = nil, prefix = nil)
      @command = command || 'secretspec'
      @file = file
      @profile = profile
      @backend = backend
      @reason = reason
      @prefix = prefix
    end

    def lookup(name)
      key = VoxgigSekreto.envkey(name, @prefix)

      args = []
      args += ['--file', @file] if @file
      args += ['get', key]
      args += ['--provider', @backend] if @backend
      args += ['--profile', @profile] if @profile
      args += ['--reason', @reason || 'sekreto']

      begin
        out, err, status = Open3.capture3(@command, *args)
      rescue SystemCallError => e
        raise SekretoError, 'sekreto: cannot run ' + @command + ': ' + e.message
      end

      # The value and one newline, and nothing else. Open3 tags the
      # child's bytes with the default external encoding, US-ASCII in a
      # stripped environment - and SecretSpec draws its errors with box
      # characters, so matching them as ASCII raises. Read both as the
      # UTF-8 they are.
      return out.force_encoding('UTF-8').sub(/\n\z/, '') if status.success?

      why = err.to_s.force_encoding('UTF-8').scrub.strip

      return nil if VoxgigSekreto.secretspecmiss(why, key)

      raise SekretoError,
            'sekreto: secretspec error: ' + (why.empty? ? 'exit ' + status.exitstatus.to_s : why)
    end

    def describe
      'secretspec' + (@backend ? ':' + @backend : '')
    end
  end

  module Plugins
    # The plugin: the `secretspec` provider kind, as a voxgig/plugin
    # definition.
    SECRETSPEC = VoxgigSekreto.providerplugin('secretspec', lambda { |spec|
      SecretspecProvider.new(spec['command'], spec['file'], spec['profile'],
                             spec['backend'], spec['reason'], spec['prefix'])
    })
  end
end
