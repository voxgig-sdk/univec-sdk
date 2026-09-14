// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/azuresecrets.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import { ProviderSpec, Provider, SekretoError, flatname, providerplugin } from '../provider/support'
import { checkaddr } from '../provider/addr'
import { fetchjson } from './httpjson'

/** Azure Key Vault.
 *
 * `api.token` reads secret `api-token` (dots flattened to `-`; Key
 * Vault names allow nothing else), current version. The token comes
 * from config, then a client-credentials login when tenant/clientid/
 * clientsecret are given, then the IMDS managed-identity endpoint - so
 * on Azure's own platform no credential configuration is needed.
 *
 * As with GCP, the IMDS call is plain http to a link-local host by
 * platform design and carries no credential; the login and vault
 * addresses are `checkaddr`-guarded. */
export function azuresecretsprovider(options?: {
  vault?: string
  token?: string
  tenant?: string
  clientid?: string
  clientsecret?: string
  loginaddr?: string
  imdsaddr?: string
  apiversion?: string
}): Provider {
  const opts = options || {}
  const resource = 'https://vault.azure.net'

  // A configured token is kept forever; logged-in and IMDS tokens carry
  // expires_in and are renewed shortly before they run out.
  let livetoken: string | undefined
  let renewat = Infinity

  const expiry = (expires: any): number => {
    const seconds = Number(expires)
    return 0 < seconds ? Date.now() + Math.max(seconds - 60, 1) * 1000 : Infinity
  }

  const login = async (): Promise<string> => {
    if (opts.token) {
      return opts.token
    }

    if (opts.tenant && opts.clientid && opts.clientsecret) {
      const loginaddr = opts.loginaddr || 'https://login.microsoftonline.com'
      checkaddr(loginaddr)

      const url = loginaddr.replace(/\/$/, '') + '/' + opts.tenant + '/oauth2/v2.0/token'
      const form =
        'grant_type=client_credentials&client_id=' +
        encodeURIComponent(opts.clientid) +
        '&client_secret=' +
        encodeURIComponent(opts.clientsecret) +
        '&scope=' +
        encodeURIComponent(resource + '/.default')

      const res = await fetchjson(
        'POST',
        url,
        { 'content-type': 'application/x-www-form-urlencoded' },
        form,
      )

      const got = res.body && res.body.access_token
      if (200 !== res.status || !got) {
        throw new SekretoError('sekreto: azure login failed: ' + res.status)
      }

      renewat = expiry(res.body.expires_in)
      return String(got)
    }

    const imds =
      (opts.imdsaddr || 'http://169.254.169.254').replace(/\/$/, '') +
      '/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' +
      encodeURIComponent(resource)

    const res = await fetchjson('GET', imds, { Metadata: 'true' })

    const got = res.body && res.body.access_token
    if (200 !== res.status || !got) {
      throw new SekretoError(
        'sekreto: azure: no token, no client credentials, and IMDS did not answer',
      )
    }

    renewat = expiry(res.body.expires_in)
    return String(got)
  }

  return {
    lookup: async (name: string) => {
      const vault = opts.vault || ''
      if ('' === vault) {
        throw new SekretoError('sekreto: azure: no vault')
      }

      // Only an explicit scheme is a URL; a vault NAMED httpvault must
      // still become https://httpvault.vault.azure.net.
      const vaulturl =
        vault.startsWith('http://') || vault.startsWith('https://')
          ? vault
          : 'https://' + vault + '.vault.azure.net'
      checkaddr(vaulturl)

      if (undefined === livetoken || Date.now() >= renewat) {
        livetoken = await login()
      }

      const url =
        vaulturl.replace(/\/$/, '') +
        '/secrets/' +
        flatname(name, '-') +
        '?api-version=' +
        (opts.apiversion || '7.4')

      const res = await fetchjson('GET', url, { authorization: 'Bearer ' + livetoken })

      if (404 === res.status) {
        return undefined
      }

      if (200 !== res.status) {
        throw new SekretoError('sekreto: azure error: ' + res.status + ': ' + url.split('?')[0])
      }

      const value = res.body && res.body.value
      return undefined === value || null === value ? undefined : String(value)
    },
    describe: () => 'azuresecrets:' + (opts.vault || ''),
  }
}


/** The plugin. Needs HTTPS. */
export const azuresecrets = providerplugin('azuresecrets', (spec: ProviderSpec) =>
  azuresecretsprovider(spec))
