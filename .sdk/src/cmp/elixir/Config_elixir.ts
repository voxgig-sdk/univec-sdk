
import {
  Content,
  File,
  Folder,
  cmp,
  configDefinition,
  configReprSetting,
  each,
  isAuthActive,
  isConfigData,
  resolveAuthPrefix,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


import {
  clean,
  formatElixir,
  elixirString,
} from './utility_elixir'


const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target
  const model: Model = ctx$.model

  const Name = model.const.Name

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  const authActive = isAuthActive(model)
  const authPrefix = resolveAuthPrefix(model)

  let baseUrl = ''
  try { baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`) } catch (_e) { }

  const authBlock = authActive
    ? `        "auth" => %{"prefix" => ${elixirString(authPrefix)}},\n`
    : ''

  const entityClean = Object.values(entity).reduce((a: any, n: any) => (a[n.name] = clean({
    fields: n.fields,
    name: n.name,
    op: n.op,
    relations: n.relations,
  }, true), a), {})

  Folder({ name: 'lib' }, () => {
    // The same config as an OBJECT, built by the shared helper so this
    // target's literal and the data that replaces it above the threshold are
    // the same config by construction. The JSON is what the threshold is
    // measured on - emitted source size varies by language, the model does not.
    // Passing target.name opts in to the main slug/version/target identity
    // fields (station descriptor input, mirrors Config_ts) - both reps below
    // render from this same def, so the data and literal branches pick the
    // fields up together.
    const { def: configDef, json: configJson } = configDefinition(model, target.name)
    const asData = isConfigData(configJson, configReprSetting(model))

    File({ name: 'config.ex' }, () => {

      // ABOVE THE THRESHOLD: emit the model as DATA.
      //
      // The literal is one nested `%{}` the Elixir compiler expands and holds
      // in the module's constant pool; a binary is one token. `Json.parse`
      // builds the vendored struct's heap nodes DIRECTLY - the same nodes
      // `Helpers.deep/1` produces from a plain map - so make_config returns
      // exactly what it returned before.
      //
      // `ProjectName.Json` is already the SDK's response decoder (see
      // `safe_json` in utility.ex), so this adds no dependency.
      if (asData) {
        Content(`# ${Name} SDK configuration
#
# THE API MODEL, EMBEDDED AS DATA (sdkgen rung L1).
#
# Emitted only above a size threshold, or when \`main.kit.config.repr\` pins
# it: for a small model the literal is smaller and far easier to read when
# debugging. Do not edit by hand.

defmodule ${Name}.Config do
  @config_data ${elixirString(configJson)}

  def make_config do
    ${Name}.Json.parse(@config_data)
  end

  # SHARED CONFIG (sdkgen rung L2).
  #
  # The SDK reads the config on every request and never writes to it, so one
  # instance is shared by every client rather than rebuilt per client. Above the
  # size threshold make_config re-parses the whole embedded JSON, so this is the
  # difference between parsing the model once and once per client.
  #
  # :persistent_term because struct nodes are ETS-backed handles: the stored
  # value is the handle, so every caller gets the same nodes. A concurrent first
  # call may build twice and the last write wins - both results are valid
  # configs, so the race is benign.
  @shared_key {__MODULE__, :shared_config}

  # The process-wide config, built once on first use.
  #
  # The returned node is SHARED: treat it as read-only. Callers that need to
  # mutate should use make_config, which always returns a fresh copy.
  #
  # VALIDATED ON READ, and this is not belt-and-braces. The struct heap is a
  # named ETS table created with no heir, so it is owned by whichever process
  # first touched struct. If that was a short-lived one - a Task, a request, an
  # ExUnit case - the table dies with it and every handle allocated in it goes
  # stale. Caching a handle in :persistent_term makes that permanent: without
  # this check the SDK hands out the dead handle for the life of the VM and
  # every getprop raises ArgumentError. Reproduced:
  #
  #     cached inside a task: {:vmap, 144}
  #     heap alive after task exit: :undefined
  #     getprop RAISED: ArgumentError
  #
  # Rebuilding on a dead handle costs one parse and restores exactly the
  # pre-L2 behaviour, so the failure degrades to "no sharing" rather than to a
  # broken SDK. The real fix is a durable owner for the heap, which belongs in
  # the struct port rather than here.
  def shared_config do
    cached = :persistent_term.get(@shared_key, nil)

    if cached != nil and usable?(cached) do
      cached
    else
      cfg = make_config()
      :persistent_term.put(@shared_key, cfg)
      cfg
    end
  end

  # Is this handle still backed by a live heap? Asked through the public API
  # rather than by inspecting the table, so it stays correct if struct changes
  # how nodes are stored.
  defp usable?(cfg) do
    Voxgig.Struct.getprop(cfg, "main")
    true
  rescue
    ArgumentError -> false
  end
end
`)
        return
      }

      Content(`# ${Name} SDK configuration
#
# Returns the resolved SDK config as vendored-struct nodes (via
# ${Name}.Helpers.deep/1). Do not edit by hand.

defmodule ${Name}.Config do
  def make_config do
    ${Name}.Helpers.deep(%{
      "main" => %{
        "name" => ${elixirString(Name)},
        "slug" => ${elixirString(String(configDef.main.slug))},
        "version" => ${elixirString(String(configDef.main.version))},
        "target" => ${elixirString(String(configDef.main.target))}
      },
      "feature" => %{
`)

      each(feature, (f: any) => {
        // From configDefinition's def, not f.config, so the literal carries
        // the feature's `transport` role (station design §8.4) beside its
        // options and cannot drift from the data rep.
        Content(`        ${elixirString(f.name)} => ${formatElixir(configDef.feature[f.name] || {}, 4)},
`)
      })

      // `options` rendered WHOLE from the canonical definition rather than
      // assembled slot by slot. Assembling it meant `options.server` - the
      // OpenAPI server-variable defaults - was simply absent from this branch,
      // so a templated server URL described a different config either side of
      // the threshold. Same fix as dart, rust and zig.
      Content(`      },
      "options" => ${formatElixir(configDef.options, 3)},
      "entity" => ${formatElixir(entityClean, 3)}
    })
  end

  # SHARED CONFIG (sdkgen rung L2). See the data branch for the rationale, and
  # for why the cached handle is validated on read.
  @shared_key {__MODULE__, :shared_config}

  # The process-wide config, built once on first use. The returned node is
  # SHARED: treat it as read-only. Callers that need to mutate should use
  # make_config, which always returns a fresh copy.
  def shared_config do
    cached = :persistent_term.get(@shared_key, nil)

    if cached != nil and usable?(cached) do
      cached
    else
      cfg = make_config()
      :persistent_term.put(@shared_key, cfg)
      cfg
    end
  end

  defp usable?(cfg) do
    Voxgig.Struct.getprop(cfg, "main")
    true
  rescue
    ArgumentError -> false
  end
end
`)
    })
  })
})


export {
  Config
}
