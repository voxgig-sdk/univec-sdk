# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/infisical.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The infisical plugin: Infisical. Needs HTTPS. A port of
# typescript/plugins/infisical.ts, which is canonical.

require 'json'

require_relative '../../voxgig_sekreto'
require_relative '../addr'
require_relative 'httpjson'

module VoxgigSekreto
  # Infisical.
  #
  # `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
  # convention is environment-style keys) at a secret path in one
  # environment of a project. Auth is a token, or a universal-auth
  # (machine identity) login with clientid/clientsecret.
  class InfisicalProvider
    def initialize(opts = nil)
      @opts = opts || {}

      # A configured token is kept forever; a universal-auth token carries
      # expiresIn and is renewed shortly before it runs out.
      @livetoken = nil
      @renewat = Float::INFINITY
    end

    def login(addr)
      return @opts['token'] if VoxgigSekreto.given(@opts['token'])

      unless VoxgigSekreto.given(@opts['clientid']) && VoxgigSekreto.given(@opts['clientsecret'])
        raise SekretoError, 'sekreto: infisical: no token and no client credentials'
      end

      status, body = VoxgigSekreto.fetchjson(
        'POST', addr + '/api/v1/auth/universal-auth/login',
        { 'content-type' => 'application/json' },
        JSON.generate('clientId' => @opts['clientid'], 'clientSecret' => @opts['clientsecret'])
      )

      got = body.is_a?(Hash) ? body['accessToken'] : nil
      unless 200 == status && VoxgigSekreto.given(got)
        raise SekretoError, 'sekreto: infisical login failed: ' + status.to_s
      end

      expires = body['expiresIn'].to_f
      @renewat = 0 < expires ? Time.now.to_f + [expires - 60, 1].max : Float::INFINITY

      got.to_s
    end

    def lookup(name)
      addr = (@opts['addr'] || 'https://app.infisical.com').sub(%r{/\z}, '')
      VoxgigSekreto.checkaddr(addr)

      project = @opts['project'] || ''
      environment = @opts['environment'] || ''
      if '' == project || '' == environment
        raise SekretoError, 'sekreto: infisical: no project/environment'
      end

      @livetoken = login(addr) if @livetoken.nil? || Time.now.to_f >= @renewat

      url = addr + '/api/v3/secrets/raw/' + VoxgigSekreto.envkey(name) +
            '?workspaceId=' + VoxgigSekreto.uriescape(project) +
            '&environment=' + VoxgigSekreto.uriescape(environment) +
            '&secretPath=' + VoxgigSekreto.uriescape(@opts['path'] || '/')

      status, body = VoxgigSekreto.fetchjson('GET', url,
                                             { 'authorization' => 'Bearer ' + @livetoken })

      return nil if 404 == status

      raise SekretoError, 'sekreto: infisical error: ' + status.to_s if 200 != status

      value = body.is_a?(Hash) && body['secret'].is_a?(Hash) ? body['secret']['secretValue'] : nil
      value.nil? ? nil : value.to_s
    end

    def describe
      'infisical:' + (@opts['project'] || '') + '/' + (@opts['environment'] || '')
    end
  end

  module Plugins
    # The plugin: the `infisical` provider kind, as a voxgig/plugin
    # definition.
    INFISICAL = VoxgigSekreto.providerplugin('infisical', lambda { |spec|
      InfisicalProvider.new(spec.slice('addr', 'token', 'clientid', 'clientsecret',
                                       'project', 'environment', 'path'))
    })
  end
end
