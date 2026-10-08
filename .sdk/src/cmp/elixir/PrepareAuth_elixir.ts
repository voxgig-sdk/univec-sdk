
import {
  Content,
  File,
  Folder,
  cmp,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
  resolveAuthPrefix,
} from '@voxgig/sdkgen'


import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


import {
  elixirString,
} from './utility_elixir'


const PrepareAuth = cmp(async function PrepareAuth(props: any) {
  const { target } = props
  const { model } = props.ctx$

  Folder({ name: model.const.name }, () => {
    File({ name: 'prepare_auth.' + target.ext }, () => {
      Content(render({
        Name: model.const.Name,
        active: authSwitchedOn(model),
        where: resolveAuthIn(model),
        name: resolveAuthName(model),
        basic: isHttpBasicAuth(model),
        // Read so the resolution is visible at generation time even though
        // the emitted code takes the prefix from options at runtime (the
        // secrets feature rewrites it there).
        prefix: resolveAuthPrefix(model),
      }))
    })
  })
})


type AuthSpec = {
  Name: string
  active: boolean
  where: string
  name: string
  basic: boolean
  prefix: string
}


function render(spec: AuthSpec): string {
  const head = `# ${spec.Name} SDK utility: prepare_auth
#
# WHERE THE CREDENTIAL GOES IS A FACT ABOUT THE API, so this module is
# GENERATED from the model rather than copied from tm/. Do not edit by hand.
#
# Extracted from ${spec.Name}.Utility, which still owns the registration
# (\`{"prepare_auth", &PrepareAuth.prepare_auth_impl/1}\`) and the
# \`prepare_auth/1\` dispatch wrapper every caller goes through. A feature that
# overrides the utility slot overrides this, exactly as before.

defmodule ${spec.Name}.PrepareAuth do
  alias Voxgig.Struct, as: S
  alias ${spec.Name}.Context

`

  if (!spec.active) {
    return head + `  # This SDK is configured with authentication off, so there is no
  # credential to place. The function stays in the pipeline because
  # make_spec calls it unconditionally and Utility registers it
  # unconditionally.
  def prepare_auth_impl(ctx) do
    spec = S.getprop(ctx, "spec")

    if spec == nil do
      {nil, Context.make_error(ctx, "auth_no_spec", "Expected context spec property to be defined.")}
    else
      {spec, nil}
    end
  end
end
`
  }

  const query = 'query' === spec.where
  const cookie = 'cookie' === spec.where

  const basicHere = spec.basic && 'header' === spec.where

  const credName = query || cookie ? spec.name : spec.name.toLowerCase()

  const attrs = `  @cred_name ${elixirString(credName)}
` +
    (cookie ? `  @cookie_header "cookie"
` : '') +
    `  @option_apikey "apikey"
` +
    (basicHere ? `  @option_secret "secret"
` : '') +
    `  @not_found "__NOTFOUND__"

`

  // The bag the credential lands in. A cookie rides the HEADER bag, because
  // a cookie IS a header.
  const bag = query
    ? `      query = S.getprop(spec, "query")`
    : `      headers = S.getprop(spec, "headers")`

  const clear = (name: string) => query
    ? `S.delprop(query, ${name})`
    : cookie
      ? `apply_cookie(headers, ${name}, nil)`
      : `S.delprop(headers, ${name})`

  const preamble = `  def prepare_auth_impl(ctx) do
    spec = S.getprop(ctx, "spec")

    if spec == nil do
      {nil, Context.make_error(ctx, "auth_no_spec", "Expected context spec property to be defined.")}
    else
${bag}
      options = opts_map(S.getprop(ctx, "client"))

      # Public APIs that need no auth omit the options.auth block entirely.
      if S.getprop(options, "auth") == nil do
        ${clear('@cred_name')}
        {spec, nil}
      else
        name = auth_name(options)

        # A credential left under the declared name would travel beside the renamed one.
        if name != @cred_name do
          ${clear('@cred_name')}
        end

        apikey = S.getprop(options, @option_apikey, @not_found)

`

  const body = basicHere
    ? `        # True HTTP Basic Auth joins the two credentials, base64-encoded - a
        # single token in the header (the branch below) can never
        # authenticate against an API that actually checks
        # \`Authorization: Basic base64(user:pass)\`. The password may be
        # empty (RFC 7617): Lob, for one, documents the key as the user with
        # a blank password (\`curl -u key:\`).
        if S.getpath(options, "auth.basic") == true do
          secret = S.getprop(options, @option_secret, @not_found)
          no_apikey = not is_binary(apikey) or apikey == @not_found or apikey == ""
          no_secret = not is_binary(secret) or secret == @not_found or secret == ""

          if no_apikey do
            S.delprop(headers, name)
          else
            ap = S.getpath(options, "auth.prefix")
            auth_prefix = if is_binary(ap), do: ap, else: ""
            b64 = Base.encode64(apikey <> ":" <> if(no_secret, do: "", else: secret))
            # The joined, encoded pair is a wire form neither credential's
            # own registration covers.
            ${spec.Name}.Utility.clean_add(ctx, b64)
            hv = if auth_prefix != "", do: auth_prefix <> " " <> b64, else: b64
            S.setprop(headers, name, hv)
          end
        else
${indent(place(spec, clear('name')), 1)}
        end
`
    : place(spec, clear('name'))

  return head + attrs + preamble + body + `
        {spec, nil}
      end
    end
  end

` + helpers(spec).replace(/\n+$/, '\n') + `end
`
}


function place(spec: AuthSpec, clear: string): string {
  const guard = `        if (is_binary(apikey) and apikey == @not_found) or apikey == nil or apikey == "" do
          ${clear}
        else
`

  if ('query' === spec.where) {
    return guard + `          apikey_val = if is_binary(apikey), do: apikey, else: ""
          # NO PREFIX IN A QUERY STRING. \`?${spec.name}=Bearer%20abc\` is not a
          # thing any API reads: the prefix is a header convention, so
          # options.auth.prefix is dropped here deliberately rather than
          # silently concatenated.
          S.setprop(query, name, apikey_val)
        end
`
  }

  if ('cookie' === spec.where) {
    return guard + `          apikey_val = if is_binary(apikey), do: apikey, else: ""
          # NO PREFIX IN A COOKIE either - a cookie carries a bare
          # \`name=value\` pair, not a header's scheme-prefixed credential.
          apply_cookie(headers, name, apikey_val)
        end
`
  }

  return guard + `          ap = S.getpath(options, "auth.prefix")
          auth_prefix = if is_binary(ap), do: ap, else: ""
          apikey_val = if is_binary(apikey), do: apikey, else: ""
          # Empty prefix (raw apiKey credential) must not add a leading space.
          hv = if auth_prefix != "", do: auth_prefix <> " " <> apikey_val, else: apikey_val
          S.setprop(headers, name, hv)
        end
`
}


function helpers(spec: AuthSpec): string {
  const authName = `  # The client's auth.name option, when set, replaces the name the API declares.
  defp auth_name(options) do
    case S.getpath(options, "auth.name") do
      given when is_binary(given) and given != "" -> ${'header' === spec.where ? 'String.downcase(given)' : 'given'}
      _ -> @cred_name
    end
  end

`

  const optsMap = authName + `  # The client's options as a MAP, cloned. The clone is load-bearing: the
  # secrets feature rewrites options.apikey on the live client, and
  # prepare_auth must read a snapshot rather than the node the feature is
  # mutating. Same body as ${spec.Name}.Utility's own private opts_map/1.
  defp opts_map(client) do
    o = S.clone(S.getprop(client, "options"))
    if S.ismap(o), do: o, else: S.jm([])
  end

`

  if ('cookie' !== spec.where) {
    return optsMap
  }

  // A cookie IS a header, and the `cookie` header is SHARED with whatever
  // cookies the caller set - so the pair is spliced in and out rather than
  // the header assigned over. Splicing also makes this idempotent: a
  // retried request cannot end up carrying the credential twice.
  return optsMap + `  # The cookie header minus the named pair, every other cookie untouched.
  defp cookies_without_cred(headers, name) do
    existing = S.getprop(headers, @cookie_header)

    if is_binary(existing) and existing != "" do
      Enum.join(${spec.Name}.Utility.cookie_keep(existing, [name]), "; ")
    else
      ""
    end
  end

  # Remove the named pair, leaving the rest of the cookie header in place.
  defp apply_cookie(headers, name, nil) do
    rest = cookies_without_cred(headers, name)

    if rest == "" do
      S.delprop(headers, @cookie_header)
    else
      S.setprop(headers, @cookie_header, rest)
    end
  end

  # Set the named pair, leaving the rest of the cookie header in place.
  defp apply_cookie(headers, name, value) do
    rest = cookies_without_cred(headers, name)
    pair = name <> "=" <> value
    S.setprop(headers, @cookie_header, if(rest == "", do: pair, else: rest <> "; " <> pair))
  end

`
}


// Indent a rendered block by `n` two-space levels, leaving blank lines blank
// (a trailing-whitespace-only line is what `mix format --check-formatted`
// reports first).
function indent(block: string, n: number): string {
  const pad = '  '.repeat(n)
  return block.split('\n')
    .map((line) => '' === line ? line : pad + line)
    .join('\n')
    .replace(/\n$/, '')
}


function authSwitchedOn(model: any): boolean {
  const auth = getModelPath(model, `main.${KIT}.config.auth`,
    { only_active: false, required: false })
  return !(null != auth && false === auth.active)
}


export {
  PrepareAuth
}
