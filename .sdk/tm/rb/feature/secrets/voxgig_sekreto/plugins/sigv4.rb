# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/sigv4.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# AWS Signature Version 4, hand-rolled - and OUTSIDE THE CORE, because it
# is the library's one cryptographic edge. Only the two aws kinds sign
# anything, which is why the core requires no hash function at all.
#
# The AWS providers need exactly one thing from the AWS SDK - request
# signing - and taking the SDK for it would break the no-dependency rule
# that keeps twenty-three ports honest. SigV4 is a stable, published
# algorithm built from HMAC-SHA256, which the standard library's openssl
# already carries.
#
# `sigv4` is pure: the caller passes the timestamp, so the same input
# yields the same signature everywhere. That is what lets the shared spec
# carry known-answer cases that every port must reproduce bit-for-bit,
# and lets the integration mock recompute the signature server-side.
#
# A port of typescript/plugins/sigv4.ts, which is canonical.

require 'openssl'
require 'uri'

# `uriescape` and `uridecode` live in httpjson, because four plugins that
# sign nothing need them too.
require_relative 'httpjson'

module VoxgigSekreto
  module_function

  def sha256hex(text)
    OpenSSL::Digest::SHA256.hexdigest(text)
  end

  def hmacsha256(key, text)
    OpenSSL::HMAC.digest('SHA256', key, text)
  end

  # The canonical query string: each pair RFC 3986-escaped, sorted by
  # escaped key then escaped value.
  def canonicalquery(query)
    return '' if query.empty?

    pairs = query.split('&', -1).map do |pair|
      eq = pair.index('=')
      key = eq.nil? ? pair : pair[0...eq]
      value = eq.nil? ? '' : pair[(eq + 1)..]
      [uriescape(uridecode(key)), uriescape(uridecode(value))]
    end

    pairs.sort.map { |key, value| key + '=' + value }.join('&')
  end

  # Sign one request. Returns the headers to attach: authorization,
  # x-amz-date, and x-amz-security-token when a session token was given.
  def sigv4(input)
    get = ->(key) { input[key.to_s].nil? ? input[key] : input[key.to_s] }

    uri = URI.parse(get.call(:url))
    datetime = get.call(:datetime)
    date = datetime[0, 8]
    body = get.call(:body) || ''
    session = get.call(:session)

    # Every header that will be signed: the caller's extras, plus host and
    # x-amz-date (and the session token when present), lower-cased and
    # trimmed the way the canonical form requires.
    # Canonical header values are trimmed AND internally collapsed -
    # AWS folds sequential whitespace to one space before signing, so a
    # header like "a  b" must sign as "a b" or the service refuses it.
    headers = {}
    (get.call(:headers) || {}).each do |key, value|
      headers[key.to_s.downcase] = value.to_s.strip.gsub(/\s+/, ' ')
    end

    # The host includes the port only when it is not the scheme's default,
    # which is how a URL prints it.
    host = uri.host
    host += ':' + uri.port.to_s if uri.port != uri.default_port
    headers['host'] = host
    headers['x-amz-date'] = datetime
    headers['x-amz-security-token'] = session unless session.nil? || '' == session

    names = headers.keys.sort
    canonicalheaders = names.map { |name| name + ':' + headers[name] + "\n" }.join
    signedheaders = names.join(';')

    path = uri.path
    path = '/' if path.empty?

    canonicalrequest = [
      get.call(:method).upcase,
      path,
      canonicalquery(uri.query || ''),
      canonicalheaders,
      signedheaders,
      sha256hex(body)
    ].join("\n")

    scope = date + '/' + get.call(:region) + '/' + get.call(:service) + '/aws4_request'

    stringtosign = [
      'AWS4-HMAC-SHA256',
      datetime,
      scope,
      sha256hex(canonicalrequest)
    ].join("\n")

    kdate = hmacsha256('AWS4' + get.call(:secret), date)
    kregion = hmacsha256(kdate, get.call(:region))
    kservice = hmacsha256(kregion, get.call(:service))
    ksigning = hmacsha256(kservice, 'aws4_request')
    signature = OpenSSL::HMAC.hexdigest('SHA256', ksigning, stringtosign)

    out = {
      'authorization' => 'AWS4-HMAC-SHA256 Credential=' + get.call(:keyid) + '/' + scope +
                         ', SignedHeaders=' + signedheaders + ', Signature=' + signature,
      'x-amz-date' => datetime
    }

    out['x-amz-security-token'] = session unless session.nil? || '' == session

    out
  end
end
