# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/httpjson.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The HTTP half of every plugin that speaks to a store over the wire, in
# one place and OUTSIDE the core: a chain of built-ins never requires this
# file. One JSON round-trip, bounded in time and in size, refusing
# redirects and ignoring proxies; and the small helpers every store client
# needs.
#
# `uriescape` lives here rather than with sigv4 because four plugins that
# never sign anything need it - azure, 1password, doppler, infisical - and
# reaching it through sigv4 would make each of them require openssl. It is
# RFC 3986 escaping, which is stricter than Ruby's own encoders: AWS wants
# `!`, `'`, `(`, `)` and `*` escaped too, and CGI.escape writes a space as
# `+`.
#
# A port of typescript/plugins/httpjson.ts, which is canonical.

require 'json'
require 'net/http'
require 'uri'

require_relative '../../voxgig_sekreto'

module VoxgigSekreto
  # How long any single vault round-trip may take before it is treated
  # as unreachable. Ports carry the same bound.
  HTTP_TIMEOUT = 10

  # How much of a response body will be read before the store is treated as
  # having answered incoherently. Ports carry the same bound.
  #
  # Far above anything real - the largest legitimate payload this library
  # fetches is Doppler's whole-config download, measured in kilobytes. A
  # bound is needed because the TIMEOUT is not one: ten seconds on a
  # loopback or datacentre link is gigabytes, and the body is accumulated in
  # memory before it is parsed. This runs on an application's startup path,
  # so the failure is the application never starting.
  HTTP_MAXBODY = 8 * 1024 * 1024

  module_function

  # One JSON round-trip, returning [status, parsed-json-or-nil]. A 404 is
  # a normal answer here, not an exception: callers decide on status
  # first. Network failure is always an error - an unreachable store is a
  # store that could not answer.
  def fetchjson(method, url, headers, body = nil)
    uri = URI.parse(url)

    request = 'POST' == method ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    headers.each { |key, value| request[key] = value }
    request.body = body unless body.nil?

    # Declared out here: the streaming block below fills it, and a variable
    # first assigned inside the block would not survive it.
    text = +''

    response = begin
      # The two nils are the proxy address and port: a secrets client dials
      # the address it was configured with and nowhere else. Left off, this
      # defaults to :ENV and reads http_proxy. Ruby's resolver does exempt
      # loopback, so the local dev vault was never exposed - but the GCP and
      # Azure metadata endpoints are not loopback, and the tokens they return
      # would have gone through the proxy.
      #
      # The timeouts are the canonical port's 10s bound. Left off, Net::HTTP
      # defaults to 60 - six times that - so a vault that accepted the
      # connection and then said nothing held an application's startup for a
      # minute per request. Measured before this: still blocked at 35s where
      # every other port had given up at 10.
      # max_retries: 0 because Net::HTTP retries an idempotent request once
      # by default, which quietly doubled the bound above - measured at 20s
      # against a silent server, not the 10 the constant says. A vault read
      # is not something to repeat on its own initiative either: the caller
      # decides whether a store that could not answer is worth asking again.
      Net::HTTP.start(uri.hostname, uri.port, nil, nil,
                      use_ssl: 'https' == uri.scheme,
                      open_timeout: HTTP_TIMEOUT,
                      read_timeout: HTTP_TIMEOUT,
                      write_timeout: HTTP_TIMEOUT,
                      max_retries: 0) do |http|
        # Streamed against HTTP_MAXBODY rather than taking response.body,
        # which buffers whatever arrives. An endless body would otherwise be
        # accumulated in memory until the deadline, which on a loopback or
        # datacentre link is gigabytes.
        http.request(request) do |res|
          res.read_body do |chunk|
            text << chunk
            if HTTP_MAXBODY < text.bytesize
              raise SekretoError,
                    'sekreto: oversized response from ' + url.split('?')[0]
            end
          end
          res
        end
      end
    rescue SekretoError
      # An endless body is a store that could not answer, so this propagates
      # rather than becoming a miss - the latter would fall through to a
      # weaker store on an attacker's cue.
      raise
    rescue StandardError => e
      raise SekretoError, 'sekreto: cannot reach ' + url.split('?')[0] + ': ' + e.message
    end

    parsed = begin
      JSON.parse(text)
    rescue JSON::ParserError, TypeError
      # A success status promised JSON; a body that does not parse means
      # the store could not answer coherently, and treating it as a miss
      # would fall through to a weaker store. Error statuses may carry
      # any body - they are decided on status alone.
      if 200 == response.code.to_i
        raise SekretoError, 'sekreto: malformed response from ' + url.split('?')[0]
      end

      nil
    end

    [response.code.to_i, parsed]
  end

  # RFC 3986 escaping, which is stricter than most library encoders: AWS
  # wants `!`, `'`, `(`, `)` and `*` escaped too.
  def uriescape(text)
    text.to_s.gsub(/[^A-Za-z0-9\-_.~]/) do |ch|
      ch.bytes.map { |byte| format('%%%02X', byte) }.join
    end
  end

  def uridecode(text)
    text.gsub(/%([0-9A-Fa-f]{2})/) { [Regexp.last_match(1)].pack('H2') }
  end
end
