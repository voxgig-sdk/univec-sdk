# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/onepassword.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The onepassword plugin: 1Password, through a Connect server. Needs
# HTTPS. A port of typescript/plugins/onepassword.ts, which is canonical.

require_relative '../../voxgig_sekreto'
require_relative '../addr'
require_relative 'httpjson'

module VoxgigSekreto
  # 1Password, through a Connect server.
  #
  # The item titled `api.token` (titles keep their dots), in the named
  # vault. The value is the field with purpose PASSWORD, or the field
  # labelled `value`. A vault that cannot be found is an error - config
  # names it, so its absence is a broken store, not a missing secret.
  class OnepasswordProvider
    def initialize(opts = nil)
      @opts = opts || {}
      @vaultid = nil
    end

    def auth
      { 'authorization' => 'Bearer ' + (@opts['token'] || '') }
    end

    def resolvevault(addr)
      want = @opts['vault'] || ''
      raise SekretoError, 'sekreto: onepassword: no vault' if '' == want

      status, body = VoxgigSekreto.fetchjson('GET', addr + '/v1/vaults', auth)

      unless 200 == status && body.is_a?(Array)
        raise SekretoError, 'sekreto: onepassword error: ' + status.to_s + ': listing vaults'
      end

      body.each do |entry|
        return entry['id'].to_s if entry.is_a?(Hash) && (want == entry['id'] || want == entry['name'])
      end

      raise SekretoError, 'sekreto: onepassword: no vault named ' + want
    end

    def lookup(name)
      VoxgigSekreto.checkname(name)

      addr = (@opts['addr'] || '').sub(%r{/\z}, '')
      raise SekretoError, 'sekreto: onepassword: no addr' if '' == addr

      VoxgigSekreto.checkaddr(addr)

      @vaultid = resolvevault(addr) if @vaultid.nil?

      filter = VoxgigSekreto.uriescape('title eq "' + name + '"')
      status, found = VoxgigSekreto.fetchjson(
        'GET', addr + '/v1/vaults/' + @vaultid + '/items?filter=' + filter, auth
      )

      unless 200 == status && found.is_a?(Array)
        raise SekretoError, 'sekreto: onepassword error: ' + status.to_s + ': finding ' + name
      end

      return nil if found.empty?

      status, item = VoxgigSekreto.fetchjson(
        'GET', addr + '/v1/vaults/' + @vaultid + '/items/' + found[0]['id'].to_s, auth
      )

      if 200 != status
        raise SekretoError, 'sekreto: onepassword error: ' + status.to_s + ': reading ' + name
      end

      fields = item.is_a?(Hash) && item['fields'].is_a?(Array) ? item['fields'] : []

      fields.each do |field|
        next unless field.is_a?(Hash) && 'PASSWORD' == field['purpose']

        return field['value'].nil? ? nil : field['value'].to_s
      end
      fields.each do |field|
        next unless field.is_a?(Hash) && 'value' == field['label']

        return field['value'].nil? ? nil : field['value'].to_s
      end

      nil
    end

    def describe
      'onepassword:' + (@opts['vault'] || '')
    end
  end

  module Plugins
    # The plugin: the `onepassword` provider kind, as a voxgig/plugin
    # definition.
    ONEPASSWORD = VoxgigSekreto.providerplugin('onepassword', lambda { |spec|
      OnepasswordProvider.new(spec.slice('addr', 'token', 'vault'))
    })
  end
end
