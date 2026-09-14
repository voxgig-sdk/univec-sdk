# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/plugins/aws.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The aws plugin: Secrets Manager and SSM Parameter Store, with requests
# SigV4-signed in-tree (sigv4.rb, beside this file). Needs HTTPS and
# HMAC-SHA256 - the one cryptographic dependency in the library, which is
# why this is a plugin and why the core requires no openssl. A port of
# typescript/plugins/aws.ts, which is canonical.

require 'json'

require_relative '../../voxgig_sekreto'
require_relative '../addr'
require_relative 'httpjson'
require_relative 'sigv4'

module VoxgigSekreto
  module_function

  # The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now.
  def awsnow
    Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
  end

  # Region and credentials, from config first and the standard AWS_*
  # environment variables second - those are AWS's own convention, and a
  # pod or CI job that has them set should just work. Missing either is
  # an error: an AWS store with no credentials could not answer.
  def awsauth(opts)
    region = opts['region'] || ENV['AWS_REGION'] || ENV['AWS_DEFAULT_REGION'] || ''
    keyid = opts['keyid'] || ENV['AWS_ACCESS_KEY_ID'] || ''
    secret = opts['secret'] || ENV['AWS_SECRET_ACCESS_KEY'] || ''
    session = opts['session'] || ENV.fetch('AWS_SESSION_TOKEN', nil)

    raise SekretoError, 'sekreto: aws: no region (set region or AWS_REGION)' if '' == region

    if '' == keyid || '' == secret
      raise SekretoError,
            'sekreto: aws: no credentials (set keyid/secret or ' \
            'AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)'
    end

    { 'region' => region, 'keyid' => keyid, 'secret' => secret, 'session' => session }
  end

  # One signed call to an AWS JSON-1.1 API.
  def awscall(opts, service, target, payload)
    auth = awsauth(opts)
    # The China partition lives under its own suffix; every other
    # commercial region is plain amazonaws.com.
    suffix = auth['region'].start_with?('cn-') ? '.amazonaws.com.cn' : '.amazonaws.com'
    addr = opts['addr'] || 'https://' + service + '.' + auth['region'] + suffix
    checkaddr(addr)

    url = addr.sub(%r{/\z}, '') + '/'
    body = JSON.generate(payload)
    headers = {
      'content-type' => 'application/x-amz-json-1.1',
      'x-amz-target' => target
    }

    signed = sigv4(
      'method' => 'POST',
      'url' => url,
      'headers' => headers,
      'body' => body,
      'service' => service,
      'region' => auth['region'],
      'keyid' => auth['keyid'],
      'secret' => auth['secret'],
      'session' => auth['session'],
      'datetime' => awsnow
    )

    fetchjson('POST', url, headers.merge(signed), body)
  end

  # Does this AWS error body name one of the not-found types? Those are
  # a miss; every other failure is a store that could not answer.
  def awsmiss(body, types)
    errtype = body.is_a?(Hash) && body['__type'].is_a?(String) ? body['__type'] : ''
    types.any? { |name| errtype.include?(name) }
  end

  # AWS Secrets Manager.
  #
  # `api.token` reads the secret named `api` (the vaultref path, so
  # `db.pass.main` reads `db/pass`) and takes the `token` field of its
  # JSON SecretString - the AWS idiom of one JSON map per secret. A
  # SecretString that is not JSON is the value itself, under the
  # conventional field `value`. Requests are SigV4-signed in-tree; see
  # sigv4.rb.
  class AwssecretsProvider
    def initialize(opts = nil)
      @opts = opts || {}
    end

    def lookup(name)
      ref = VoxgigSekreto.vaultref(name)

      status, body = VoxgigSekreto.awscall(@opts, 'secretsmanager',
                                           'secretsmanager.GetSecretValue',
                                           { 'SecretId' => ref['path'] })

      return nil if 400 == status && VoxgigSekreto.awsmiss(body, ['ResourceNotFoundException'])

      raise SekretoError, 'sekreto: aws secretsmanager error: ' + status.to_s if 200 != status

      text = body.is_a?(Hash) ? body['SecretString'] : nil

      unless text.is_a?(String)
        # A binary secret has no fields to address; only the conventional
        # `value` field can mean "the bytes themselves".
        bin = body.is_a?(Hash) ? body['SecretBinary'] : nil
        if bin.is_a?(String) && 'value' == ref['field']
          # 'm' skips characters outside the alphabet, so a corrupted
          # payload decoded to plausible-looking bytes that were then
          # returned as the secret. 'm0' is strict. A store that answered
          # incoherently is an error, never a miss.
          decoded = begin
            bin.unpack1('m0')
          rescue ArgumentError
            raise SekretoError, 'sekreto: aws secretsmanager: undecodable secret'
          end

          return decoded.force_encoding('UTF-8')
        end

        return nil
      end

      parsed = begin
        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end

      if parsed.is_a?(Hash)
        value = parsed[ref['field']]
        return value.nil? ? nil : value.to_s
      end

      # A plain-string secret is the whole value; it has no named fields.
      'value' == ref['field'] ? text : nil
    end

    # Config only, never the environment: describe feeds the spec's
    # sources group, which must answer the same everywhere.
    def describe
      'awssecrets:' + (@opts['region'] || '')
    end
  end

  # AWS SSM Parameter Store.
  #
  # `db.pass.main` reads the parameter `/db/pass/main` (under an optional
  # prefix path), decrypted. Parameter Store carries flat strings, so
  # there is no field indirection.
  class AwsparamsProvider
    def initialize(opts = nil)
      @opts = opts || {}
    end

    def lookup(name)
      status, body = VoxgigSekreto.awscall(@opts, 'ssm', 'AmazonSSM.GetParameter',
                                           { 'Name' => VoxgigSekreto.awsparam(name, @opts['prefix']),
                                             'WithDecryption' => true })

      return nil if 400 == status && VoxgigSekreto.awsmiss(body, ['ParameterNotFound'])

      raise SekretoError, 'sekreto: aws ssm error: ' + status.to_s if 200 != status

      value = body.is_a?(Hash) && body['Parameter'].is_a?(Hash) ? body['Parameter']['Value'] : nil
      value.nil? ? nil : value.to_s
    end

    def describe
      'awsparams:' + (@opts['region'] || '') + (@opts['prefix'] || '')
    end
  end

  module Plugins
    # The plugins: the `awssecrets` and `awsparams` provider kinds, as
    # voxgig/plugin definitions. Two kinds, one module, because they share
    # the signing and the credential resolution.
    # A local, not a constant: everything Plugins holds is a definition,
    # and a stray constant beside them reads like an eleventh plugin.
    awskeys = %w[region keyid secret session addr].freeze

    AWSSECRETS = VoxgigSekreto.providerplugin('awssecrets', lambda { |spec|
      AwssecretsProvider.new(spec.slice(*awskeys))
    })

    AWSPARAMS = VoxgigSekreto.providerplugin('awsparams', lambda { |spec|
      AwsparamsProvider.new(spec.slice(*awskeys, 'prefix'))
    })
  end
end
