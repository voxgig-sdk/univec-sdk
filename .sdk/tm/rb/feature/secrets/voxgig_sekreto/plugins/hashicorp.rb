# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/hashicorp.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The hashicorp plugin: HashiCorp Vault, and OpenBao. Needs HTTPS, and
# the filesystem for a kubernetes service-account JWT. A port of
# typescript/plugins/hashicorp.ts, which is canonical.

require 'json'

require_relative '../../voxgig_sekreto'
require_relative '../addr'
require_relative 'httpjson'

module VoxgigSekreto
  # HashiCorp Vault.
  #
  # KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api`
  # and takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
  # `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means
  # "not here" - a miss - so a vault can sit in a chain with fallbacks.
  #
  # A Vault Enterprise namespace rides the X-Vault-Namespace header, on
  # logins as well as reads.
  #
  # Instead of being handed a token, the provider can log in: Kubernetes
  # auth (the pod's service-account JWT, from its conventional path) or
  # AppRole. A failed login is an error, never a miss - it means this
  # store could not answer at all.
  class HashicorpProvider
    def initialize(addr, token, options = nil)
      opts = options || {}
      @addr = addr
      @mount = opts['mount'] || 'secret'
      @kv = opts['kv'] || 2
      @vaultnamespace = opts['vaultnamespace']
      @auth = opts['auth']

      # A version typo like kv: 3 must not quietly behave as v2 and turn
      # its 404s into misses; there is nothing safe to assume it meant.
      if 1 != @kv && 2 != @kv
        raise SekretoError, 'sekreto: hashicorp: unsupported kv version: ' + @kv.to_s
      end

      # The working token: a configured token is kept forever, a logged-in
      # token is renewed shortly before its lease runs out - a long-running
      # process must not keep presenting a token the vault already expired.
      @livetoken = VoxgigSekreto.given(token) ? token : nil
      @renewat = Float::INFINITY
    end

    def baseheaders
      headers = {}
      headers['X-Vault-Namespace'] = @vaultnamespace if @vaultnamespace
      headers
    end

    def login
      raise SekretoError, 'sekreto: hashicorp: no token and no auth method' if @auth.nil?

      method = @auth['method']
      mount = @auth['mount'] || method
      url = @addr.sub(%r{/\z}, '') + '/v1/auth/' + mount.to_s + '/login'

      body = if 'kubernetes' == method
               jwt = @auth['jwt']
               if jwt.nil?
                 file = @auth['jwtfile'] || '/var/run/secrets/kubernetes.io/serviceaccount/token'
                 jwt = begin
                   File.read(file).strip
                 rescue StandardError
                   raise SekretoError, 'sekreto: hashicorp: cannot read jwt file ' + file
                 end
               end
               { 'role' => @auth['role'] || '', 'jwt' => jwt }
             elsif 'approle' == method
               { 'role_id' => @auth['roleid'] || '', 'secret_id' => @auth['secretid'] || '' }
             else
               raise SekretoError, 'sekreto: hashicorp: unknown auth method: ' + method.to_s
             end

      status, resbody = VoxgigSekreto.fetchjson('POST', url, baseheaders, JSON.generate(body))

      got = resbody.is_a?(Hash) && resbody['auth'].is_a?(Hash) ? resbody['auth']['client_token'] : nil
      unless 200 == status && VoxgigSekreto.given(got)
        raise SekretoError, 'sekreto: hashicorp login failed: ' + status.to_s + ': ' + url
      end

      lease = resbody['auth']['lease_duration'].to_f
      @renewat = 0 < lease ? Time.now.to_f + [lease - 60, 1].max : Float::INFINITY

      got.to_s
    end

    def lookup(name)
      VoxgigSekreto.checkaddr(@addr)

      @livetoken = login if @livetoken.nil? || Time.now.to_f >= @renewat

      ref = VoxgigSekreto.vaultref(name)
      base = @addr.sub(%r{/\z}, '') + '/v1/' + @mount
      url = 1 == @kv ? base + '/' + ref['path'] : base + '/data/' + ref['path']

      headers = baseheaders
      headers['X-Vault-Token'] = @livetoken

      status, body = VoxgigSekreto.fetchjson('GET', url, headers)

      return nil if 404 == status

      raise SekretoError, 'sekreto: hashicorp error: ' + status.to_s + ': ' + url if 200 != status

      data = if 1 == @kv
               body.is_a?(Hash) ? body['data'] : nil
             else
               body.is_a?(Hash) && body['data'].is_a?(Hash) ? body['data']['data'] : nil
             end
      value = data.is_a?(Hash) ? data[ref['field']] : nil

      value.nil? ? nil : value.to_s
    end

    def describe
      'hashicorp:' + @addr + '/' + @mount
    end
  end

  module Plugins
    # The plugin: the `hashicorp` provider kind, as a voxgig/plugin
    # definition.
    HASHICORP = VoxgigSekreto.providerplugin('hashicorp', lambda { |spec|
      HashicorpProvider.new(spec['addr'] || '', spec['token'] || '',
                            spec.slice('mount', 'kv', 'vaultnamespace', 'auth'))
    })
  end
end
