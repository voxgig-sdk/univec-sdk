// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (javascript/plugins/aws.js)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

// A port of typescript/plugins/aws.ts, which is canonical.

const {
  SekretoError, awsparam, providerplugin, unbase64, vaultref,
} = require('../provider/support')
const { checkaddr } = require('../provider/addr')
const { sigv4 } = require('./sigv4')
const { fetchjson } = require('./httpjson')

/** The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now. */
function awsnow() {
  return new Date()
    .toISOString()
    .replace(/[-:]/g, '')
    .replace(/\.\d+Z$/, 'Z')
}

/** Region and credentials, from config first and the standard AWS_*
 * environment variables second - those are AWS's own convention, and a
 * pod or CI job that has them set should just work. Missing either is
 * an error: an AWS store with no credentials could not answer. */
function awsauth(opts) {
  const env = process.env

  const region = opts.region || env.AWS_REGION || env.AWS_DEFAULT_REGION || ''
  const keyid = opts.keyid || env.AWS_ACCESS_KEY_ID || ''
  const secret = opts.secret || env.AWS_SECRET_ACCESS_KEY || ''
  const session = opts.session || env.AWS_SESSION_TOKEN || undefined

  if ('' === region) {
    throw new SekretoError('sekreto: aws: no region (set region or AWS_REGION)')
  }
  if ('' === keyid || '' === secret) {
    throw new SekretoError(
      'sekreto: aws: no credentials (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)',
    )
  }

  return { region, keyid, secret, session }
}

/** One signed call to an AWS JSON-1.1 API. */
async function awscall(opts, service, target, payload) {
  const auth = awsauth(opts)
  // The China partition lives under its own suffix; every other
  // commercial region is plain amazonaws.com.
  const suffix = auth.region.startsWith('cn-') ? '.amazonaws.com.cn' : '.amazonaws.com'
  const addr = opts.addr || 'https://' + service + '.' + auth.region + suffix
  checkaddr(addr)

  const url = addr.replace(/\/$/, '') + '/'
  const body = JSON.stringify(payload)
  const headers = {
    'content-type': 'application/x-amz-json-1.1',
    'x-amz-target': target,
  }

  const signed = sigv4({
    method: 'POST',
    url,
    headers,
    body,
    service,
    region: auth.region,
    keyid: auth.keyid,
    secret: auth.secret,
    session: auth.session,
    datetime: awsnow(),
  })

  return fetchjson('POST', url, { ...headers, ...signed }, body)
}

/** Does this AWS error body name one of the not-found types? Those are
 * a miss; every other failure is a store that could not answer. */
function awsmiss(body, types) {
  const errtype = body && 'string' === typeof body.__type ? body.__type : ''
  return types.some((name) => errtype.includes(name))
}

/** AWS Secrets Manager.
 *
 * `api.token` reads the secret named `api` (the vaultref path, so
 * `db.pass.main` reads `db/pass`) and takes the `token` field of its
 * JSON SecretString - the AWS idiom of one JSON map per secret. A
 * SecretString that is not JSON is the value itself, under the
 * conventional field `value`. Requests are SigV4-signed in-tree; see
 * sigv4.js. */
function awssecretsprovider(options) {
  const opts = options || {}

  return {
    lookup: async (name) => {
      const ref = vaultref(name)

      const res = await awscall(opts, 'secretsmanager', 'secretsmanager.GetSecretValue', {
        SecretId: ref.path,
      })

      if (400 === res.status && awsmiss(res.body, ['ResourceNotFoundException'])) {
        return undefined
      }

      if (200 !== res.status) {
        throw new SekretoError('sekreto: aws secretsmanager error: ' + res.status)
      }

      const text = res.body && res.body.SecretString

      if ('string' !== typeof text) {
        // A binary secret has no fields to address; only the conventional
        // `value` field can mean "the bytes themselves".
        const bin = res.body && res.body.SecretBinary
        if ('string' === typeof bin && 'value' === ref.field) {
          const decoded = unbase64(bin)
          if (undefined === decoded) {
            throw new SekretoError('sekreto: aws secretsmanager: undecodable secret')
          }
          return decoded
        }
        return undefined
      }

      let parsed
      try {
        parsed = JSON.parse(text)
      } catch (_err) {
        parsed = undefined
      }

      if (parsed && 'object' === typeof parsed && !Array.isArray(parsed)) {
        const value = parsed[ref.field]
        return undefined === value || null === value ? undefined : String(value)
      }

      // A plain-string secret is the whole value; it has no named fields.
      return 'value' === ref.field ? text : undefined
    },
    // Config only, never the environment: describe() feeds the spec's
    // sources group, which must answer the same everywhere.
    describe: () => 'awssecrets:' + (opts.region || ''),
  }
}

/** AWS SSM Parameter Store.
 *
 * `db.pass.main` reads the parameter `/db/pass/main` (under an optional
 * prefix path), decrypted. Parameter Store carries flat strings, so
 * there is no field indirection. */
function awsparamsprovider(options) {
  const opts = options || {}

  return {
    lookup: async (name) => {
      const res = await awscall(opts, 'ssm', 'AmazonSSM.GetParameter', {
        Name: awsparam(name, opts.prefix),
        WithDecryption: true,
      })

      if (400 === res.status && awsmiss(res.body, ['ParameterNotFound'])) {
        return undefined
      }

      if (200 !== res.status) {
        throw new SekretoError('sekreto: aws ssm error: ' + res.status)
      }

      const value = res.body && res.body.Parameter && res.body.Parameter.Value
      return undefined === value || null === value ? undefined : String(value)
    },
    describe: () => 'awsparams:' + (opts.region || '') + (opts.prefix || ''),
  }
}

/** The two plugins. Both need HTTPS and HMAC-SHA256 - the one crypto
 * dependency in the library, which is why this is a plugin rather than
 * a built-in: `sigv4` is exported from here and from nowhere in the
 * core. */
const awssecrets = providerplugin('awssecrets', (spec) => awssecretsprovider(spec))

const awsparams = providerplugin('awsparams', (spec) => awsparamsprovider(spec))

module.exports = { awsparams, awsparamsprovider, awssecrets, awssecretsprovider, sigv4 }
