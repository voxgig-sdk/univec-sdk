# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/doppler.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The doppler plugin: Doppler. Needs HTTPS. A port of
# typescript/plugins/doppler.ts, which is canonical.

require_relative '../../voxgig_sekreto'
require_relative '../addr'
require_relative 'httpjson'

module VoxgigSekreto
  # Doppler.
  #
  # The whole config is downloaded once - Doppler's own bulk endpoint -
  # and answered from memory, like a remote .env: `api.token` is the
  # `API_TOKEN` entry. A service token is config-scoped, so project and
  # config are only needed with broader tokens.
  class DopplerProvider
    def initialize(opts = nil)
      @opts = opts || {}
      @values = nil
    end

    def load
      return @values unless @values.nil?

      addr = (@opts['addr'] || 'https://api.doppler.com').sub(%r{/\z}, '')
      VoxgigSekreto.checkaddr(addr)

      url = addr + '/v3/configs/config/secrets/download?format=json'
      url += '&project=' + VoxgigSekreto.uriescape(@opts['project']) if VoxgigSekreto.given(@opts['project'])
      url += '&config=' + VoxgigSekreto.uriescape(@opts['config']) if VoxgigSekreto.given(@opts['config'])

      status, body = VoxgigSekreto.fetchjson(
        'GET', url, { 'authorization' => 'Bearer ' + (@opts['token'] || '') }
      )

      raise SekretoError, 'sekreto: doppler error: ' + status.to_s if 200 != status || !body.is_a?(Hash)

      @values = {}
      body.each { |key, value| @values[key] = value.to_s unless value.nil? }

      @values
    end

    def lookup(name)
      load[VoxgigSekreto.envkey(name)]
    end

    def describe
      return 'doppler' unless VoxgigSekreto.given(@opts['project'])

      'doppler:' + @opts['project'] + '/' + (@opts['config'] || '')
    end
  end

  module Plugins
    # The plugin: the `doppler` provider kind, as a voxgig/plugin
    # definition.
    DOPPLER = VoxgigSekreto.providerplugin('doppler', lambda { |spec|
      DopplerProvider.new(spec.slice('token', 'project', 'config', 'addr'))
    })
  end
end
