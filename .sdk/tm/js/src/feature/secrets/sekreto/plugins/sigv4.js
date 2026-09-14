// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (javascript/plugins/sigv4.js)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Signature Version 4, hand-rolled.
//
// The AWS providers need exactly one thing from the AWS SDK - request
// signing - and taking the SDK for it would break the no-dependency rule
// that keeps twenty-three ports honest. SigV4 is a stable, published
// algorithm built from HMAC-SHA256, which node's own crypto already has.
//
// `sigv4` is pure: the caller passes the timestamp, so the same input
// yields the same signature everywhere. That is what lets the shared spec
// carry known-answer cases that all the ports must reproduce bit-for-bit,
// and lets the integration mock recompute the signature server-side.
//
// A port of typescript/plugins/sigv4.ts, which is canonical.

// node:crypto is loaded ON FIRST USE, not at require time.
//
// This module lives under plugins/ and is reached only through the aws
// plugin, so the core never sees it at all; deferring the builtin on top
// of that keeps requiring the plugin free of side effects too, and lets
// the sigv4 conformance group run on a runtime that has crypto without
// anything else in the module graph having asked for it.
//
// require(), not `await import()`: these helpers are synchronous and are
// called from synchronous signing code.
function crypto() {
  try {
    return require('node:crypto')
  } catch (err) {
    throw new Error(
      'sekreto: AWS request signing needs node:crypto, which this runtime ' +
        'does not provide: ' +
        err.message,
      { cause: err },
    )
  }
}

function sha256hex(text) {
  return crypto().createHash('sha256').update(text, 'utf8').digest('hex')
}

function hmac(key, text) {
  return crypto().createHmac('sha256', key).update(text, 'utf8').digest()
}

/** RFC 3986 escaping, which is stricter than encodeURIComponent: AWS
 * wants `!`, `'`, `(`, `)` and `*` escaped too. */
function uriescape(text) {
  return encodeURIComponent(text).replace(
    /[!'()*]/g,
    (ch) => '%' + ch.charCodeAt(0).toString(16).toUpperCase(),
  )
}

/** The canonical query string: each pair RFC 3986-escaped, sorted by
 * escaped key then escaped value. */
function canonicalquery(query) {
  if ('' === query) {
    return ''
  }

  const pairs = query.split('&').map((pair) => {
    const eq = pair.indexOf('=')
    const key = -1 === eq ? pair : pair.slice(0, eq)
    const value = -1 === eq ? '' : pair.slice(eq + 1)
    return [uriescape(decodeURIComponent(key)), uriescape(decodeURIComponent(value))]
  })

  pairs.sort((left, right) => {
    if (left[0] !== right[0]) {
      return left[0] < right[0] ? -1 : 1
    }
    return left[1] < right[1] ? -1 : left[1] > right[1] ? 1 : 0
  })

  return pairs.map((pair) => pair[0] + '=' + pair[1]).join('&')
}

/** Sign one request. Returns the headers to attach: authorization,
 * x-amz-date, and x-amz-security-token when a session token was given. */
function sigv4(input) {
  const url = new URL(input.url)

  const date = input.datetime.slice(0, 8)
  const body = input.body || ''

  // Every header that will be signed: the caller's extras, plus host and
  // x-amz-date (and the session token when present), lower-cased and
  // trimmed the way the canonical form requires.
  // Canonical header values are trimmed AND internally collapsed -
  // AWS folds sequential whitespace to one space before signing, so a
  // header like "a  b" must sign as "a b" or the service refuses it.
  const headers = {}
  for (const [key, value] of Object.entries(input.headers || {})) {
    headers[key.toLowerCase()] = String(value).trim().replace(/\s+/g, ' ')
  }
  headers['host'] = url.host
  headers['x-amz-date'] = input.datetime
  if (input.session) {
    headers['x-amz-security-token'] = input.session
  }

  const names = Object.keys(headers).sort()
  const canonicalheaders = names.map((name) => name + ':' + headers[name] + '\n').join('')
  const signedheaders = names.join(';')

  const canonicalrequest = [
    input.method.toUpperCase(),
    url.pathname || '/',
    canonicalquery(url.search.replace(/^\?/, '')),
    canonicalheaders,
    signedheaders,
    sha256hex(body),
  ].join('\n')

  const scope = date + '/' + input.region + '/' + input.service + '/aws4_request'

  const stringtosign = [
    'AWS4-HMAC-SHA256',
    input.datetime,
    scope,
    sha256hex(canonicalrequest),
  ].join('\n')

  const kdate = hmac('AWS4' + input.secret, date)
  const kregion = hmac(kdate, input.region)
  const kservice = hmac(kregion, input.service)
  const ksigning = hmac(kservice, 'aws4_request')
  const signature = crypto()
    .createHmac('sha256', ksigning)
    .update(stringtosign, 'utf8')
    .digest('hex')

  const out = {
    authorization:
      'AWS4-HMAC-SHA256 Credential=' +
      input.keyid +
      '/' +
      scope +
      ', SignedHeaders=' +
      signedheaders +
      ', Signature=' +
      signature,
    'x-amz-date': input.datetime,
  }

  if (input.session) {
    out['x-amz-security-token'] = input.session
  }

  return out
}

module.exports = { sigv4 }
