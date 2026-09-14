# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/boru.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The boru plugin: a boru vault, through its own CLI or its own wire
# protocol. Needs a child process, and HTTPS for the wire path. A port of
# typescript/plugins/boru.ts, which is canonical.

require 'open3'

require_relative '../../voxgig_sekreto'
require_relative '../addr'
require_relative 'httpjson'

module VoxgigSekreto
  # A boru vault (https://github.com/boru-lang/boru).
  #
  # Two ways in, both boru's own.
  #
  # With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
  # secret on stdout and nothing else. The passphrase is read by boru
  # itself from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as
  # config and never puts it on a command line, where it would show up in
  # the process table.
  #
  # With an `addr`, boru's wire protocol: `boru vault serve` publishes a
  # read-only, HashiCorp-shaped provision API (boru's
  # design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
  # from `boru vault grant`. A sekreto name is already a valid boru
  # alias, and boru aliases keep their dots, so `api.token` is the single
  # path segment `api.token` - not the `api`/`token` split a HashiCorp KV
  # gets. The value is the `value` field. A 404 is a miss; anything else
  # the server refuses (a revoked capability, a sealed vault) is an
  # error.
  #
  # boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
  # credential *broker*, built precisely so the caller never receives the
  # credential. `vault serve` is the provision endpoint, built to hand
  # the value back - that is the one sekreto uses.
  class BoruProvider
    def initialize(command = nil, namespace = nil, home = nil, addr = nil, token = nil, mount = nil)
      @command = command || 'boru'
      @namespace = namespace
      @home = home
      @addr = VoxgigSekreto.given(addr) ? addr.sub(%r{/\z}, '') : nil
      @token = token
      @mount = mount || 'secret'
    end

    def wirelookup(name)
      VoxgigSekreto.checkname(name)
      VoxgigSekreto.checkaddr(@addr)

      alias_name = @namespace ? @namespace + '/' + name : name
      url = @addr + '/v1/' + @mount + '/data/' + alias_name

      status, body = VoxgigSekreto.fetchjson('GET', url, { 'X-Vault-Token' => @token || '' })

      return nil if 404 == status

      raise SekretoError, 'sekreto: boru serve error: ' + status.to_s + ': ' + url if 200 != status

      data = body.is_a?(Hash) && body['data'].is_a?(Hash) ? body['data']['data'] : nil
      value = data.is_a?(Hash) ? data['value'] : nil

      value.nil? ? nil : value.to_s
    end

    def lookup(name)
      return wirelookup(name) if @addr

      VoxgigSekreto.checkname(name)

      alias_name = @namespace ? @namespace + ':' + name : name
      env = @home ? { 'BORU_HOME' => @home } : {}

      begin
        out, err, status = Open3.capture3(env, @command, 'vault', 'get', '--reveal', alias_name)
      rescue SystemCallError => e
        raise SekretoError, 'sekreto: cannot run ' + @command + ': ' + e.message
      end

      # boru prints the value and one newline, and nothing else.
      return out.sub(/\n\z/, '') if status.success?

      why = err.to_s.strip

      # "no alias named" is boru saying it does not hold this secret, which is
      # a miss: the chain carries on to the next provider. A locked vault or a
      # wrong passphrase is not a miss - treating it as one would fall through
      # to a weaker store without saying so.
      return nil if VoxgigSekreto.borumiss(why)

      raise SekretoError,
            'sekreto: boru vault error: ' + (why.empty? ? 'exit ' + status.exitstatus.to_s : why)
    end

    def describe
      return 'boru:' + @addr if @addr

      'boru' + (@namespace ? ':' + @namespace : '')
    end
  end

  module_function

  # Does this boru failure mean "no such secret" rather than "I could not
  # answer"? Matched on boru's own wording for a missing alias.
  def borumiss(why)
    why.include?('no alias named')
  end

  module Plugins
    # The plugin: the `boru` provider kind, as a voxgig/plugin definition.
    BORU = VoxgigSekreto.providerplugin('boru', lambda { |spec|
      BoruProvider.new(spec['command'], spec['namespace'], spec['home'],
                       spec['addr'], spec['token'], spec['mount'])
    })
  end
end
