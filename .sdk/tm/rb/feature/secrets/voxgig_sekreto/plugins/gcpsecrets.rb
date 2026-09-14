# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/gcpsecrets.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The gcpsecrets plugin: GCP Secret Manager. Needs HTTPS. A port of
# typescript/plugins/gcpsecrets.ts, which is canonical.

require_relative '../../voxgig_sekreto'
require_relative '../addr'
require_relative 'httpjson'

module VoxgigSekreto
  # GCP Secret Manager.
  #
  # `api.token` reads secret `api_token` (dots flattened to `_`; Secret
  # Manager ids have no hierarchy and reject dots), latest version. The
  # token comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the
  # GCE/GKE metadata server - so on Google's own platform no credential
  # configuration is needed at all.
  #
  # The metadata call itself is plain http to a link-local host by
  # platform design; no credential rides on it, so `checkaddr` guards the
  # Secret Manager address instead.
  class GcpsecretsProvider
    def initialize(opts = nil)
      @opts = opts || {}

      # A configured token is kept forever; a metadata-server token carries
      # expires_in and is renewed shortly before it runs out.
      @livetoken = nil
      @renewat = Float::INFINITY
    end

    def metadataaddr
      return @opts['metadataaddr'] if VoxgigSekreto.given(@opts['metadataaddr'])

      host = ENV.fetch('GCE_METADATA_HOST', nil)
      VoxgigSekreto.given(host) ? 'http://' + host : 'http://metadata.google.internal'
    end

    def login
      configured = @opts['token'] || ENV.fetch('GOOGLE_OAUTH_ACCESS_TOKEN', nil)
      return configured if VoxgigSekreto.given(configured)

      url = metadataaddr.sub(%r{/\z}, '') +
            '/computeMetadata/v1/instance/service-accounts/default/token'

      status, body = VoxgigSekreto.fetchjson('GET', url, { 'Metadata-Flavor' => 'Google' })

      got = body.is_a?(Hash) ? body['access_token'] : nil
      unless 200 == status && VoxgigSekreto.given(got)
        raise SekretoError, 'sekreto: gcp: no token and metadata server did not answer'
      end

      expires = body['expires_in'].to_f
      @renewat = 0 < expires ? Time.now.to_f + [expires - 60, 1].max : Float::INFINITY

      got.to_s
    end

    def lookup(name)
      project = @opts['project'] || ''
      raise SekretoError, 'sekreto: gcp: no project' if '' == project

      addr = @opts['addr'] || 'https://secretmanager.googleapis.com'
      VoxgigSekreto.checkaddr(addr)

      @livetoken = login if @livetoken.nil? || Time.now.to_f >= @renewat

      url = addr.sub(%r{/\z}, '') + '/v1/projects/' + project + '/secrets/' +
            VoxgigSekreto.flatname(name, '_') + '/versions/latest:access'

      status, body = VoxgigSekreto.fetchjson('GET', url,
                                             { 'authorization' => 'Bearer ' + @livetoken })

      return nil if 404 == status

      raise SekretoError, 'sekreto: gcp error: ' + status.to_s + ': ' + url if 200 != status

      data = body.is_a?(Hash) && body['payload'].is_a?(Hash) ? body['payload']['data'] : nil
      return nil unless data.is_a?(String)

      # See the aws provider: strict, and an undecodable payload is an
      # error rather than a miss.
      decoded = begin
        data.unpack1('m0')
      rescue ArgumentError
        raise SekretoError, 'sekreto: gcp: undecodable secret'
      end

      decoded.force_encoding('UTF-8')
    end

    def describe
      'gcpsecrets:' + (@opts['project'] || '')
    end
  end

  module Plugins
    # The plugin: the `gcpsecrets` provider kind, as a voxgig/plugin
    # definition.
    GCPSECRETS = VoxgigSekreto.providerplugin('gcpsecrets', lambda { |spec|
      GcpsecretsProvider.new(spec.slice('project', 'token', 'addr', 'metadataaddr'))
    })
  end
end
