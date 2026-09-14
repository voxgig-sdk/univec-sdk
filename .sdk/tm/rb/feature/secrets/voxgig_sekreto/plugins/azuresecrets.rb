# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/azuresecrets.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The azuresecrets plugin: Azure Key Vault. Needs HTTPS. A port of
# typescript/plugins/azuresecrets.ts, which is canonical.

require_relative '../../voxgig_sekreto'
require_relative '../addr'
require_relative 'httpjson'

module VoxgigSekreto
  # Azure Key Vault.
  #
  # `api.token` reads secret `api-token` (dots flattened to `-`; Key
  # Vault names allow nothing else), current version. The token comes
  # from config, then a client-credentials login when tenant/clientid/
  # clientsecret are given, then the IMDS managed-identity endpoint - so
  # on Azure's own platform no credential configuration is needed.
  #
  # As with GCP, the IMDS call is plain http to a link-local host by
  # platform design and carries no credential; the login and vault
  # addresses are `checkaddr`-guarded.
  class AzuresecretsProvider
    RESOURCE = 'https://vault.azure.net'

    def initialize(opts = nil)
      @opts = opts || {}

      # A configured token is kept forever; logged-in and IMDS tokens carry
      # expires_in and are renewed shortly before they run out.
      @livetoken = nil
      @renewat = Float::INFINITY
    end

    def expiry(expires)
      seconds = expires.to_f
      0 < seconds ? Time.now.to_f + [seconds - 60, 1].max : Float::INFINITY
    end

    def login
      return @opts['token'] if VoxgigSekreto.given(@opts['token'])

      if VoxgigSekreto.given(@opts['tenant']) && VoxgigSekreto.given(@opts['clientid']) &&
         VoxgigSekreto.given(@opts['clientsecret'])
        loginaddr = @opts['loginaddr'] || 'https://login.microsoftonline.com'
        VoxgigSekreto.checkaddr(loginaddr)

        url = loginaddr.sub(%r{/\z}, '') + '/' + @opts['tenant'] + '/oauth2/v2.0/token'
        form = 'grant_type=client_credentials' \
               '&client_id=' + VoxgigSekreto.uriescape(@opts['clientid']) +
               '&client_secret=' + VoxgigSekreto.uriescape(@opts['clientsecret']) +
               '&scope=' + VoxgigSekreto.uriescape(RESOURCE + '/.default')

        status, body = VoxgigSekreto.fetchjson(
          'POST', url, { 'content-type' => 'application/x-www-form-urlencoded' }, form
        )

        got = body.is_a?(Hash) ? body['access_token'] : nil
        unless 200 == status && VoxgigSekreto.given(got)
          raise SekretoError, 'sekreto: azure login failed: ' + status.to_s
        end

        @renewat = expiry(body['expires_in'])
        return got.to_s
      end

      imds = (@opts['imdsaddr'] || 'http://169.254.169.254').sub(%r{/\z}, '') +
             '/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' +
             VoxgigSekreto.uriescape(RESOURCE)

      status, body = VoxgigSekreto.fetchjson('GET', imds, { 'Metadata' => 'true' })

      got = body.is_a?(Hash) ? body['access_token'] : nil
      unless 200 == status && VoxgigSekreto.given(got)
        raise SekretoError,
              'sekreto: azure: no token, no client credentials, and IMDS did not answer'
      end

      @renewat = expiry(body['expires_in'])
      got.to_s
    end

    def lookup(name)
      vault = @opts['vault'] || ''
      raise SekretoError, 'sekreto: azure: no vault' if '' == vault

      # Only an explicit scheme is a URL; a vault NAMED httpvault must
      # still become https://httpvault.vault.azure.net.
      vaulturl = if vault.start_with?('http://', 'https://')
                   vault
                 else
                   'https://' + vault + '.vault.azure.net'
                 end
      VoxgigSekreto.checkaddr(vaulturl)

      @livetoken = login if @livetoken.nil? || Time.now.to_f >= @renewat

      url = vaulturl.sub(%r{/\z}, '') + '/secrets/' + VoxgigSekreto.flatname(name, '-') +
            '?api-version=' + (@opts['apiversion'] || '7.4')

      status, body = VoxgigSekreto.fetchjson('GET', url,
                                             { 'authorization' => 'Bearer ' + @livetoken })

      return nil if 404 == status

      if 200 != status
        raise SekretoError, 'sekreto: azure error: ' + status.to_s + ': ' + url.split('?')[0]
      end

      value = body.is_a?(Hash) ? body['value'] : nil
      value.nil? ? nil : value.to_s
    end

    def describe
      'azuresecrets:' + (@opts['vault'] || '')
    end
  end

  module Plugins
    # The plugin: the `azuresecrets` provider kind, as a voxgig/plugin
    # definition.
    AZURESECRETS = VoxgigSekreto.providerplugin('azuresecrets', lambda { |spec|
      AzuresecretsProvider.new(spec.slice('vault', 'token', 'tenant', 'clientid',
                                          'clientsecret', 'loginaddr', 'imdsaddr',
                                          'apiversion'))
    })
  end
end
