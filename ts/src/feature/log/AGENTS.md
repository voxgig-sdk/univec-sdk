# LogFeature — Agent Guide

Structured request and response logging (v0.0.1).

A **feature** is a pipeline extension: an object of hooks that fire at named
stages of every entity operation (load, list, create, update, remove) and of
the SDK/entity lifecycle. Features are how you inspect or modify the request
pipeline without forking the SDK. This directory holds the **generated**
runtime for the `log` feature in the TypeScript target — do
not edit it by hand; change its template/model in `.sdk/` and regenerate.

Active by default: **yes** (`config.options.active`
in the model). It runs unless disabled.

## Hooks it fires

- `GetData`
- `GetMatch`
- `PostConstruct`
- `PostConstructEntity`
- `PrePoint`
- `PreRequest`
- `PreResponse`
- `PreResult`
- `PreSpec`
- `SetData`
- `SetMatch`

Each active hook runs at its pipeline stage in feature-registration order, so a
later feature can override an earlier one.

## Where it is defined

| Part | Path |
| --- | --- |
| Model definition | `.sdk/model/feature/log.aon` (name, title, version, `config.options.active`, the `hook` map, per-language `deps`) |
| Registered in | `.sdk/model/feature/feature-index.aon` (`@"log.aon"`) |
| Runtime template | `.sdk/tm/ts/src/feature/log/` (copied here on `generate`; `FEATURE_Name`/`FEATURE_VERSION` substituted) |

(Paths are relative to the **project root** — four levels up from here.)

## Customising this feature

- **Turn hooks on/off**: edit the `hook` map in
  `.sdk/model/feature/log.aon` (`<Stage>: active: true|false`).
- **Change default activation**: set `config.options.active` in the same file.
- **Dependencies**: edit `deps.<lang>` in the same file.
- **Behaviour**: edit the runtime template under
  `.sdk/tm/ts/src/feature/log/`, then regenerate.

After any change: `cd ../../../../.sdk && npm run generate` (add
`npm run build` first if you changed a component). If a regenerated file
shows a literal `FEATURE_Name`/`ProjectName`, delete it and regenerate.

To author a **new** feature, copy this one's model + template shape — see the
[project guide](../../../../AGENTS.md) and the
[TypeScript guide](../../../AGENTS.md).
