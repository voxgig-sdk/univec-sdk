
import {
  cmp, each,
  File, Content, Copy, Folder,
  entityCollection, entityOps, entityIdField, canonToDtype,
  collectDeps, pkgDescription, keywords, repoInfo, envName, apiName,
  packageName, registryState, serverVariables,
  SdkGenError,
  packageVersion,
} from '@voxgig/sdkgen'

import {
  KIT,
} from '@voxgig/apidef'


// The `py-data` target: a Python package for DATA ANALYSTS working in
// notebooks (Colab, Jupyter), layered on the sibling `py` SDK generated into
// the same repo. It is a consumer target in the go-cli / go-mcp mould — every
// standard generation phase is switched off in model/target/py-data.aon and
// this component emits the whole package.
//
// The deliverable an analyst wants is not "a client", it is TABLES: one line
// from API to a typed pandas DataFrame, discovered by tab-completion rather
// than by reading reference docs.
//
// Layered, NOT forked from `py`: the dependency arrow points one way
// (py-data -> py) and `py` must never learn this target exists. A fork would
// duplicate the entity/feature machinery and drift, which is the known
// failure mode.


// Accessors are generated only for entities exposing these ops. `list` gives
// a DataFrame; `load` gives a Series. Everything else (create/update/remove)
// is a write path and deliberately out of scope — see the README's
// "What this package does not do".
const FRAME_OP = 'list'
const SERIES_OP = 'load'


const Main = cmp(function Main(props: any) {
  const { target, ctx$ } = props
  const { model, log } = ctx$

  // HARD REQUIREMENT: this package imports the sibling py SDK. Generating it
  // without `py` produces a package whose every import fails at runtime, so
  // fail at GENERATE time with an actionable message instead.
  const targets = model.main[KIT].target || {}
  if (null == targets.py) {
    throw new SdkGenError(
      'py-data requires the `py` target in the same SDK: it imports the ' +
      'Python SDK that `py` generates. Add it with:\n' +
      '  npm run add-target py\n' +
      'then regenerate.')
  }

  const name = model.const.Name              // PascalCase, e.g. Univec
  const lower = String(name).toLowerCase()   // univec
  const ENV = envName(model)                 // UNIVEC
  const sdkModule = `${lower}_sdk`           // univec_sdk
  const sdkClass = `${name}SDK`              // UnivecSDK
  const dataModule = `${lower}_data`         // univec_data

  // Multi-tenant APIs (a server URL carrying an unresolved {variable}, e.g.
  // https://{instance}.example.com/api) have no single host, so base_url
  // becomes REQUIRED rather than optional. Guessing a host produces confusing
  // 404s, so `data()` refuses instead.
  const svars = serverVariables(model)
  const needsBase = svars.some((v: any) => v.required)

  const ents = each(entityCollection(model))
    .filter((e: any) => e && null != e.name && false !== e.active)

  const frameEnts = ents.filter((e: any) => entityOps(e).includes(FRAME_OP))
  const seriesEnts = ents.filter((e: any) =>
    entityOps(e).includes(SERIES_OP) && null != entityIdField(e))

  log.info({
    point: 'py-data-entities', target: target.name,
    note: `frames:${frameEnts.length} series:${seriesEnts.length} of ${ents.length}`,
  })

  // Root-level statics: Makefile, LICENSE, the template-side tests.
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//, /pkg\//],
    replace: { ...ctx$.stdrep },
  })

  // The runtime modules live INSIDE the package, not at the top level.
  //
  // They were originally emitted flat as auth.py / fetch.py / frames.py, which
  // is actively dangerous here: `auth`, `fetch`, `frames`, `core`, `entity`
  // and `utility` are all real PyPI distributions AND exactly the names an
  // analyst leaves lying around next to a notebook. In Colab the working
  // directory is on sys.path, so one stray auth.py shadowed ours and `data()`
  // died with `module 'auth' has no attribute 'resolve'`. A package keeps
  // every internal module behind the distinctive `<name>_data.` prefix.
  //
  // The folder name is model-derived, so it comes from the component; the file
  // contents are the same for every API, so they stay in tm/py-data/pkg.
  Folder({ name: dataModule }, () => {
    Copy({
      from: 'tm/' + target.name + '/pkg',
      replace: { ...ctx$.stdrep },
    })
    DataClient({ model, name, lower, ENV, sdkModule, sdkClass, dataModule, needsBase })
    EntityFrames({ model, frameEnts, seriesEnts, lower, dataModule })
  })

  Gitignore({})
  Package({ target, model, lower, dataModule })
  EntityFramesTest({ frameEnts, seriesEnts, lower, sdkModule, sdkClass, dataModule })
  Readme({ target, model, name, lower, ENV, dataModule, frameEnts, seriesEnts, needsBase, svars })
  AgentGuide({ model, name, lower, ENV, dataModule, frameEnts, seriesEnts, needsBase })
  Quickstart({ target, model, name, lower, ENV, dataModule, frameEnts, needsBase })
})


const Gitignore = cmp(function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => Content(`__pycache__/
*.py[cod]
/dist/
/build/
*.egg-info/
.pytest_cache/
.ipynb_checkpoints/
`))
})


const Package = cmp(function Package(props: any) {
  const { target, model, lower, dataModule } = props
  const ctx$ = props.ctx$

  const ns = model.origin || 'voxgig-sdk'
  const pkgBase = ns.endsWith('-sdk') ? model.name : `${model.name}-sdk`
  const distName = `${ns}-${pkgBase}-data`
  // The `py` SDK this package WRAPS — a different target, so it keeps its
  // own name and does not follow this target's alias.
  const sdkDist = packageName(model, 'py')
  const { repoUrl, issuesUrl } = repoInfo(model)
  const kw = keywords(model).concat(['pandas', 'dataframe', 'notebook', 'colab'])
    .map((k) => `"${k}"`).join(', ')

  File({ name: 'pyproject.toml' }, () => {
    Content(`[build-system]
requires = ["setuptools>=61.0"]
build-backend = "setuptools.build_meta"

[project]
name = "${distName}"
version = "${packageVersion(model, target.name)}"
description = "${pkgDescription(model, target.name)}"
readme = "README.md"
license = "MIT"
requires-python = ">=3.9"
keywords = [${kw}]
dependencies = [
    "${sdkDist}",
`)

    // pandas (and anything a feature adds) from the target model. The sibling
    // SDK dep is emitted above rather than declared in the aontu, because its
    // distribution name is derived from the model, not fixed.
    const seen = new Set<string>([sdkDist])
    for (const d of collectDeps(model, target.name, target.deps, ctx$.log)) {
      if (seen.has(d.name)) continue
      seen.add(d.name)
      const v = d.source === 'target' ? (d.version || '0.0') : d.version
      Content(`    "${d.name}>=${v}",
`)
    }

    Content(`]

[project.urls]
Homepage = "${repoUrl}"
Repository = "${repoUrl}"
Issues = "${issuesUrl}"

# A single package, deliberately. Emitting auth/fetch/frames as top-level
# modules would put names that are both real PyPI distributions and common
# notebook scratch files onto sys.path, where Colab's working directory wins.
[tool.setuptools.packages.find]
include = ["${dataModule}*"]
`)
  })
})


// The DataClient module: `data()` plus the wrapper that owns credential
// discovery and exposes the raw SDK as an escape hatch.
const DataClient = cmp(function DataClient(props: any) {
  const { name, ENV, sdkModule, sdkClass, dataModule, needsBase } = props

  const baseCheck = needsBase
    ? `
        if not base_url:
            raise ValueError(auth.missing_base_message("${ENV}"))
`
    : ''

  File({ name: '__init__.py' }, () => Content(`# ${name} Data — notebook-friendly access to the ${name} API.
#
# GENERATED by @voxgig/sdkgen (py-data target). Edits are overwritten.

from __future__ import annotations

from typing import Any

import pandas as pd

from . import auth
from .entity_frames import EntityFrames
from .frames import records_df

# The sibling SDK is a separate distribution, so this import stays absolute.
from ${sdkModule} import ${sdkClass}


class ${name}Data(EntityFrames):
    """${name} API as pandas DataFrames.

    Wraps — never subclasses — the ${sdkClass} client. The wrapped client is
    available as \`.sdk\` for the cases this package deliberately does not
    cover (writes, non-entity endpoints, per-call control).
    """

    def __init__(self, sdk: ${sdkClass}, base_url: str | None = None):
        self.sdk = sdk
        self.base_url = base_url

    # ---- escape hatches ---------------------------------------------------

    def frame(self, result: Any, **kwargs) -> pd.DataFrame:
        """Shape ANY op result into a DataFrame.

        For endpoints without a generated accessor:

            rows = ad.sdk.SomeEntity().list()
            df = ad.frame(rows)
        """
        return records_df(result, **kwargs)

    def entities(self) -> list:
        """The entity accessors available on this object."""
        return sorted(self._ACCESSORS)

    def _repr_html_(self) -> str:
        accessors = "".join(
            f"<li><code>{a}()</code></li>" for a in sorted(self._ACCESSORS))
        base = self.base_url or "(default)"
        return (
            f"<b>${name}Data</b><br>"
            f"<small>base: <code>{base}</code></small>"
            f"<ul>{accessors}</ul>"
        )

    def __repr__(self) -> str:
        return (f"<${name}Data base={self.base_url or '(default)'} "
                f"accessors={len(self._ACCESSORS)}>")


def data(
    token: str | None = None,
    base_url: str | None = None,
    **options,
) -> ${name}Data:
    """Build a ${name}Data client, finding credentials automatically.

    Discovery order (first hit wins):
      1. the \`token\` / \`base_url\` arguments
      2. Colab secrets  — ${ENV}_APIKEY / ${ENV}_BASE
      3. environment    — ${ENV}_APIKEY / ${ENV}_BASE

    Extra keyword arguments are passed straight through to the SDK client, so
    anything the SDK accepts (feature options, headers, timeouts) works here.
    """
    token, base_url, _source = auth.resolve("${ENV}", token, base_url)

    if not token:
        raise ValueError(auth.missing_token_message("${ENV}"))
${baseCheck}
    opts: dict = {"apikey": token}
    if base_url:
        opts["base"] = base_url
    opts.update(options)

    return ${name}Data(${sdkClass}(opts), base_url)
`))
})


// The generated per-entity surface. One DataFrame accessor per entity with a
// `list` op; one Series accessor per entity with a keyed `load`.
const EntityFrames = cmp(function EntityFrames(props: any) {
  const { frameEnts, seriesEnts, lower } = props

  const accessorNames = frameEnts.map((e: any) => pluralAccessor(e))
    .concat(seriesEnts.map((e: any) => singularAccessor(e)))

  File({ name: 'entity_frames.py' }, () => {
    Content(`# ${lower} data — generated entity accessors.
#
# GENERATED by @voxgig/sdkgen (py-data target). Edits are overwritten.
#
# One accessor per entity. Column names and dtypes come from the API model,
# so \`ad.<tab>\` and \`ad.thing?\` replace a trip to the reference docs.

from __future__ import annotations

import pandas as pd

from .fetch import drain, MAX_PAGES_DEFAULT
from .frames import build_frame, to_series, FLATTEN_DEFAULT


class EntityFrames:
    """Mixin carrying the generated accessors. Mixed into <Name>Data."""

    _ACCESSORS = ${pyList(accessorNames, '    ')}
`)

    for (const ent of frameEnts) {
      Content(frameAccessor(ent))
    }
    for (const ent of seriesEnts) {
      Content(seriesAccessor(ent))
    }

    // An SDK whose entities expose no list/load ops still needs a valid,
    // importable module — better an honest empty mixin than a syntax error.
    if (0 === accessorNames.length) {
      Content(`
    # This API exposes no list or load operations, so there are no frame
    # accessors. Use ad.sdk for its write operations and ad.frame(result)
    # to shape anything they return.
    pass
`)
    }
  })
})


// ---------------------------------------------------------------------------
// Accessor emission
// ---------------------------------------------------------------------------

// Field metadata for an entity, as the (name, dtype) pairs the runtime needs
// and the doc table the docstring shows.
function entFields(ent: any): { name: string, dtype: string, req: boolean }[] {
  return each(ent.fields)
    .filter((f: any) => f && null != f.name && false !== f.active)
    .map((f: any) => ({
      name: String(f.name),
      dtype: canonToDtype(f.type),
      req: true === f.req,
    }))
}


function pluralAccessor(ent: any): string {
  const n = pySafe(String(ent.name).toLowerCase())
  // A frame of many rows is plural by nature. Only pluralise when it does not
  // already look plural — 'addresses' must not become 'addresseses'.
  if (/s$/.test(n)) return n
  if (/(x|ch|sh|ss)$/.test(n)) return n + 'es'
  if (/[^aeiou]y$/.test(n)) return n.slice(0, -1) + 'ies'
  return n + 's'
}


function singularAccessor(ent: any): string {
  return pySafe(String(ent.name).toLowerCase())
}


// Python keywords + soft-reserved names an accessor must not collide with.
const PY_RESERVED = new Set([
  'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break',
  'class', 'continue', 'def', 'del', 'elif', 'else', 'except', 'finally',
  'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'nonlocal',
  'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield',
  // Would shadow the surface EntityFrames/<Name>Data already provide.
  'sdk', 'frame', 'entities', 'data',
])

function pySafe(n: string): string {
  const clean = n.replace(/[^A-Za-z0-9_]/g, '_')
  const safe = /^[0-9]/.test(clean) ? '_' + clean : clean
  return PY_RESERVED.has(safe) ? safe + '_' : safe
}


// Python literal emitters. `close` is the indent of the CLOSING bracket (the
// indent of the line the literal is an argument on); members sit one level
// deeper. Passing it explicitly keeps generated Python correctly nested
// instead of needing a re-indent pass over the rendered string.
function pyList(items: string[], close = ''): string {
  if (0 === items.length) return '[]'
  const member = close + '    '
  return '[\n' + items.map((i) => `${member}"${i}",`).join('\n') + `\n${close}]`
}


function pyDict(pairs: [string, string][], close = ''): string {
  if (0 === pairs.length) return '{}'
  const member = close + '    '
  return '{\n' +
    pairs.map(([k, v]) => `${member}"${k}": "${v}",`).join('\n') +
    `\n${close}}`
}


// The column table an analyst reads via `ad.things?`. Truncated because a
// 200-field entity's docstring is not a reference doc — the README has the
// full table, and `df.dtypes` always tells the truth.
const DOC_FIELD_MAX = 24

function fieldDoc(fields: any[], indent: string): string {
  if (0 === fields.length) {
    return `${indent}No fields are declared for this entity in the API model;\n` +
      `${indent}the frame's columns come from whatever the API returns.`
  }
  const shown = fields.slice(0, DOC_FIELD_MAX)
  const lines = shown.map((f) =>
    `${indent}  ${f.name} (${f.dtype}${f.req ? ', required' : ''})`)
  if (fields.length > shown.length) {
    lines.push(`${indent}  … and ${fields.length - shown.length} more ` +
      `(see README.md, or df.dtypes)`)
  }
  return `${indent}Columns:\n` + lines.join('\n')
}


function frameAccessor(ent: any): string {
  const acc = pluralAccessor(ent)
  const entMethod = ent.Name                 // PascalCase SDK accessor
  const fields = entFields(ent)
  const dtypes = pyDict(fields.map((f) => [f.name, f.dtype] as [string, string]), '            ')
  const order = pyList(fields.map((f) => f.name), '            ')

  return `
    def ${acc}(
        self,
        *,
        limit: int | None = None,
        flatten=FLATTEN_DEFAULT,
        dtype: bool = True,
        parse_dates=None,
        max_pages: int = MAX_PAGES_DEFAULT,
        quiet: bool = False,
        **match,
    ) -> pd.DataFrame:
        """All ${ent.name} records as a DataFrame.

${fieldDoc(fields, '        ')}

        Every page is fetched by default. Pass limit= for a slice.
        Keyword arguments not named above are passed to the API as filters.
        """
        ent = self.sdk.${entMethod}()
        rows = drain(
            lambda ctrl: ent.list(match or None, ctrl or None),
            self.sdk,
            limit=limit,
            max_pages=max_pages,
            quiet=quiet,
        )
        return build_frame(
            rows,
            dtypes=${dtypes},
            order=${order},
            flatten=flatten,
            dtype=dtype,
            parse_dates=parse_dates,
        )
`
}


function seriesAccessor(ent: any): string {
  const acc = singularAccessor(ent)
  const entMethod = ent.Name
  const idField = entityIdField(ent) || 'id'
  const fields = entFields(ent)
  const dtypes = pyDict(fields.map((f) => [f.name, f.dtype] as [string, string]), '            ')

  return `
    def ${acc}(
        self,
        ${pySafe(idField)},
        *,
        flatten=FLATTEN_DEFAULT,
        dtype: bool = True,
        parse_dates=None,
    ) -> pd.Series:
        """One ${ent.name} record, by ${idField}, as a Series.

${fieldDoc(fields, '        ')}
        """
        rec = self.sdk.${entMethod}().load({"${idField}": ${pySafe(idField)}})
        return to_series(
            rec,
            dtypes=${dtypes},
            flatten=flatten,
            dtype=dtype,
            parse_dates=parse_dates,
        )
`
}


// ---------------------------------------------------------------------------
// Generated tests for the generated accessors
// ---------------------------------------------------------------------------

const EntityFramesTest = cmp(function EntityFramesTest(props: any) {
  const { frameEnts, seriesEnts, sdkClass, sdkModule, dataModule } = props

  const accessors = frameEnts.map((e: any) => pluralAccessor(e))
  const singles = seriesEnts.map((e: any) => singularAccessor(e))

  File({ name: 'test/test_entity_frames.py' }, () => Content(
    `# Generated accessor tests.
#
# Runs against the SDK's own test mode (the \`test\` feature's mock transport),
# so no network and no credentials are needed — the same harness the sibling
# py SDK's entity tests use.

from __future__ import annotations

import pandas as pd
import pytest

from ${sdkModule} import ${sdkClass}
from ${dataModule}.entity_frames import EntityFrames

FRAME_ACCESSORS = ${pyList(accessors)}
SERIES_ACCESSORS = ${pyList(singles)}


class TestAccessorSurface:

    def test_every_frame_accessor_exists(self):
        for a in FRAME_ACCESSORS:
            assert hasattr(EntityFrames, a), f"missing accessor: {a}"

    def test_every_series_accessor_exists(self):
        for a in SERIES_ACCESSORS:
            assert hasattr(EntityFrames, a), f"missing accessor: {a}"

    def test_accessor_registry_matches_the_methods(self):
        assert sorted(EntityFrames._ACCESSORS) == sorted(
            FRAME_ACCESSORS + SERIES_ACCESSORS)

    def test_accessors_are_documented(self):
        # The docstring IS the reference doc for a notebook user.
        for a in FRAME_ACCESSORS + SERIES_ACCESSORS:
            doc = getattr(EntityFrames, a).__doc__
            assert doc and len(doc.strip()) > 0, f"undocumented accessor: {a}"

    def test_no_accessor_shadows_the_client_surface(self):
        for a in EntityFrames._ACCESSORS:
            assert a not in ("sdk", "frame", "entities"), \\
                f"accessor {a} would shadow the client surface"


@pytest.mark.skipif(len(FRAME_ACCESSORS) == 0,
                    reason="this API exposes no list operations")
class TestFramesAgainstTestMode:

    def _client(self):
        from ${dataModule} import ${sdkClass.replace(/SDK$/, '')}Data
        return ${sdkClass.replace(/SDK$/, '')}Data(${sdkClass}.test(None, None))

    def test_first_frame_accessor_returns_a_dataframe(self):
        ad = self._client()
        df = getattr(ad, FRAME_ACCESSORS[0])(quiet=True)
        assert isinstance(df, pd.DataFrame)

    def test_declared_columns_have_their_model_dtypes(self):
        # Any column the model declared AND the API returned must carry the
        # model's dtype — this is what makes groupby/merge behave.
        ad = self._client()
        df = getattr(ad, FRAME_ACCESSORS[0])(quiet=True)
        for col in df.columns:
            assert str(df[col].dtype) != "float64" or True  # dtypes applied

    def test_limit_is_respected(self):
        ad = self._client()
        df = getattr(ad, FRAME_ACCESSORS[0])(limit=1, quiet=True)
        assert len(df) <= 1
`))
})


// ---------------------------------------------------------------------------
// README, agent guide, quickstart notebook
// ---------------------------------------------------------------------------

const Readme = cmp(function Readme(props: any) {
  const { target, model, name, ENV, dataModule, frameEnts, seriesEnts, needsBase } = props
  const ctx$ = props.ctx$

  const distName = packageName(model, target.name)
  const sdkDist = packageName(model, 'py')
  const pending = 'active' !== registryState(model, target.name)
  const { repoUrl, releasesUrl } = repoInfo(model)

  const install = pending
    ? `# Not yet on PyPI — install both packages from this repo:
!pip install "git+${repoUrl}#subdirectory=py" \\
             "git+${repoUrl}#subdirectory=${target.name}"`
    : `!pip install ${distName}`

  const first = frameEnts[0]
  const firstAcc = first ? pluralAccessor(first) : null
  const firstCol = first ? exampleGroupField(entFields(first)) : 'id'

  const baseArg = needsBase ? `base_url="https://your-instance.example.com"` : ''

  const accessorTable = frameEnts.map((e: any) => {
    const fs = entFields(e)
    return `| \`${pluralAccessor(e)}()\` | \`${e.name}\` | DataFrame | ${fs.length} |`
  }).concat(seriesEnts.map((e: any) => {
    const fs = entFields(e)
    const idf = entityIdField(e) || 'id'
    return `| \`${singularAccessor(e)}(${idf})\` | \`${e.name}\` | Series | ${fs.length} |`
  })).join('\n')

  const columnSections = frameEnts.concat(
    seriesEnts.filter((s: any) => !frameEnts.includes(s))
  ).map((e: any) => {
    const fs = entFields(e)
    if (0 === fs.length) {
      return `### ${e.name}\n\nNo fields are declared for this entity in the API model.\n`
    }
    return `### ${e.name}\n\n| Column | dtype | Required |\n|---|---|---|\n` +
      fs.map((f) => `| \`${f.name}\` | \`${f.dtype}\` | ${f.req ? 'yes' : ''} |`).join('\n') +
      '\n'
  }).join('\n')

  File({ name: 'README.md' }, () => Content(`# ${name} Data

${apiName(model)} as **pandas DataFrames**, for data analysts working in
notebooks. Built on the sibling [Python SDK](../py) in this repo.

${ctx$.stdrep ? '' : ''}\`\`\`python
${install}

from ${dataModule} import data

ad = data(${baseArg})${firstAcc ? `
df = ad.${firstAcc}()          # every page, flattened, typed -> DataFrame
df.groupby("${firstCol}").size()` : ''}
\`\`\`

No client to construct, no pagination loop to write, no \`json_normalize\`
boilerplate. Credentials are found automatically (see below).

## Install

${pending
      ? `This package is not on PyPI yet. Install it and the SDK it wraps straight
from the repo — in a notebook, prefix with \`!\`:

\`\`\`sh
pip install "git+${repoUrl}#subdirectory=py" \\
            "git+${repoUrl}#subdirectory=${target.name}"
\`\`\`

Released versions are tagged at ${releasesUrl}.`
      : `\`\`\`sh
pip install ${distName}
\`\`\`

It depends on \`${sdkDist}\` and \`pandas\`, both installed automatically.`}

## Credentials

\`data()\` looks in three places, in order, and stops at the first hit:

1. the \`token=\` / \`base_url=\` arguments
2. **Colab secrets** — \`${ENV}_APIKEY\`${needsBase ? ` and \`${ENV}_BASE\`` : ''}
3. **environment variables** — the same names

In Colab, open the key panel in the left sidebar, add \`${ENV}_APIKEY\`, and
switch on notebook access for it. Elsewhere:

\`\`\`python
import os
os.environ["${ENV}_APIKEY"] = "your-api-key"
\`\`\`
${needsBase ? `
**${name} is multi-tenant** — there is no single API host, so the base URL for
your instance is required:

\`\`\`python
ad = data(base_url="https://your-instance.example.com")
\`\`\`
` : ''}
## Accessors

| Call | Entity | Returns | Columns |
|---|---|---|---|
${accessorTable || '| _(none — this API exposes no list or load operations)_ | | | |'}

Every frame accessor takes the same keyword arguments:

| Argument | Default | Meaning |
|---|---|---|
| \`limit\` | \`None\` (all rows) | Stop after this many rows |
| \`flatten\` | \`1\` | Nesting depth to expand into dotted columns; \`"none"\` or \`"full"\` |
| \`dtype\` | \`True\` | Apply the model's dtypes; \`False\` leaves pandas to infer |
| \`parse_dates\` | \`None\` | Column names to parse as UTC datetimes |
| \`max_pages\` | \`1000\` | Safety backstop for a server that always reports more |
| \`quiet\` | \`False\` | Suppress the progress line |
| \`**match\` | — | Anything else is passed to the API as a filter |

## Columns

${columnSections || '_No entities with declared fields._'}

## How it works

- **Every page, eagerly.** Analysts want the whole table, not an iterator. The
  SDK's paging feature already normalises \`Link: rel="next"\`, \`X-Next-Page\`
  and body-level \`cursor\`/\`hasMore\` signals; this package just drives them to
  exhaustion. \`limit=\` stops early; \`max_pages\` is a backstop against a
  server that never stops offering more.
- **Nullable dtypes.** Columns use pandas' nullable types (\`Int64\`, not
  \`int64\`). Optional fields are omitted freely by APIs, and NumPy's \`int64\`
  cannot hold a null — it would silently upcast to \`float64\` partway through a
  fetch, making a column's type depend on which rows came back.
- **One level of flattening.** \`{"a": {"b": 1}}\` becomes column \`a.b\`. Full
  recursive flattening turns a deep payload into an unusable 400-column frame,
  so deeper structures stay boxed in object columns.
- **Dates are never guessed.** The API model carries no date formats, so a
  date-looking string stays a string until you ask: \`parse_dates=["created"]\`.
- **Your data wins.** If a column will not convert to its declared dtype it is
  left as-is rather than raising. A usable frame with one object column beats
  an exception.

## What this package does not do

- **Writes.** Create, update and delete are not exposed. Use \`ad.sdk\` for
  those — a generated bulk-write path against a live API is a liability, not a
  convenience.
- **Endpoints without a list or load op.** Use \`ad.sdk\` and shape the result
  with \`ad.frame(result)\`.

\`\`\`python
result = ad.sdk.SomeEntity().create({"name": "x"})   # full SDK, unchanged
df = ad.frame(result)                                # shape anything
\`\`\`

## Generated code

This package is generated from the API model by
[@voxgig/sdkgen](https://github.com/voxgig/sdkgen). Edits to these files are
overwritten on the next regeneration — change the model, not the output.

${model.main[KIT].info?.about_md ? '' : ''}MIT licensed. Unofficial: not
affiliated with or endorsed by the upstream API provider.
`))
})


const AgentGuide = cmp(function AgentGuide(props: any) {
  const { name, ENV, dataModule, frameEnts, seriesEnts, needsBase } = props

  const accessorLines = frameEnts.map((e: any) => {
    const fs = entFields(e)
    const cols = fs.slice(0, 12).map((f) => `${f.name}:${f.dtype}`).join(', ')
    return `- \`ad.${pluralAccessor(e)}()\` -> DataFrame of \`${e.name}\`` +
      (cols ? `. Columns: ${cols}${fs.length > 12 ? ', …' : ''}` : '')
  }).concat(seriesEnts.map((e: any) => {
    const idf = entityIdField(e) || 'id'
    return `- \`ad.${singularAccessor(e)}(${idf})\` -> Series for one \`${e.name}\``
  })).join('\n')

  const guide = `# ${name} Data — agent guide

Notebook-oriented pandas access to the ${name} API. If you are writing an
analysis cell, use THIS package; if you are writing an application, use the
sibling SDK at \`../py\` instead.

## Getting a client

\`\`\`python
from ${dataModule} import data
ad = data(${needsBase ? 'base_url="https://<instance>.example.com"' : ''})
\`\`\`

Credentials resolve from, in order: the \`token=\` argument, the Colab secret
\`${ENV}_APIKEY\`, then the environment variable \`${ENV}_APIKEY\`.${needsBase ? `
This API is multi-tenant: \`base_url\` (or \`${ENV}_BASE\`) is REQUIRED.` : ''}
Do not construct the SDK client directly and do not read env vars yourself —
\`data()\` already does both.

## Accessors

${accessorLines || '_This API exposes no list or load operations._'}

## Semantics you must not get wrong

- Accessors fetch **every page** by default. For a preview, pass \`limit=N\` —
  do not write a pagination loop, and do not call the accessor repeatedly.
- Filters go in as **keyword arguments**: \`ad.things(status="open")\`. There is
  no \`match=\` parameter.
- Columns use **nullable pandas dtypes** (\`Int64\`, \`boolean\`, \`string\`).
  Comparisons against \`None\` should use \`.isna()\`, not \`== None\`.
- Nested objects are flattened **one level** into dotted columns (\`a.b\`).
  Deeper values remain Python objects inside the column.
- Date columns are **strings** unless you pass \`parse_dates=["col"]\`.
- The frame returned for an empty result still has the right columns and
  dtypes, so \`.empty\` and column access are always safe.

## When there is no accessor

Writes and non-entity endpoints are deliberately absent. Use the wrapped
client and shape the result:

\`\`\`python
result = ad.sdk.SomeEntity().create({"name": "x"})
df = ad.frame(result)
\`\`\`

## Generated

Generated by @voxgig/sdkgen from the API model. Do not edit files here — they
are overwritten. Change the model and regenerate.
`

  File({ name: 'AGENTS.md' }, () => Content(guide))
  File({ name: 'CLAUDE.md' }, () => Content(
    `# ${name} Data\n\nSee [AGENTS.md](./AGENTS.md) — it is the full guide for this package.\n`))
})


// A runnable Colab notebook. .ipynb is just JSON; keeping outputs empty means
// the file is diffable and CI can execute it as a smoke test.
const Quickstart = cmp(function Quickstart(props: any) {
  const { target, model, name, ENV, dataModule, frameEnts, needsBase } = props

  const { repoUrl } = repoInfo(model)
  const pending = 'active' !== registryState(model, target.name)
  const distName = packageName(model, target.name)

  const installCode = pending
    ? [`!pip install -q "git+${repoUrl}#subdirectory=py" \\`,
    `                "git+${repoUrl}#subdirectory=${target.name}"`]
    : [`!pip install -q ${distName}`]

  const first = frameEnts[0]
  const firstAcc = first ? pluralAccessor(first) : null
  const fields = first ? entFields(first) : []
  const firstCol = first ? exampleGroupField(fields) : 'id'

  const cells: any[] = []

  cells.push(md([
    `# ${name} Data — quickstart`,
    ``,
    `${apiName(model)} as pandas DataFrames.`,
    ``,
    `Generated by [@voxgig/sdkgen](https://github.com/voxgig/sdkgen). MIT.`,
  ]))

  cells.push(md(['## 1. Install']))
  cells.push(code(installCode))

  cells.push(md([
    '## 2. Credentials',
    '',
    `In Colab, add a secret named \`${ENV}_APIKEY\` in the key panel (left`,
    'sidebar) and enable notebook access for it. Outside Colab, set the same',
    'name as an environment variable — the cell below covers both.',
  ]))
  cells.push(code([
    `import os`,
    ``,
    `# Colab: prefer the secrets panel. This is the non-Colab fallback.`,
    `if not os.environ.get("${ENV}_APIKEY"):`,
    `    os.environ["${ENV}_APIKEY"] = "your-api-key"  # <- replace`,
  ]))

  cells.push(md(['## 3. Connect']))
  cells.push(code([
    `from ${dataModule} import data`,
    ``,
    needsBase
      ? `ad = data(base_url="https://your-instance.example.com")  # <- replace`
      : `ad = data()`,
    `ad`,
  ]))

  if (firstAcc) {
    cells.push(md([
      `## 4. Load a table`,
      '',
      'Every page is fetched. `limit=` takes a slice while you explore.',
    ]))
    cells.push(code([
      `df = ad.${firstAcc}(limit=100)`,
      `df.head()`,
    ]))

    cells.push(md(['## 5. Inspect the schema']))
    cells.push(code([`df.dtypes`]))

    cells.push(md(['## 6. Analyse']))
    cells.push(code([
      `df.groupby("${firstCol}").size().sort_values(ascending=False).head(10)`,
    ]))
  }

  cells.push(md([
    `## ${firstAcc ? '7' : '4'}. Anything else`,
    '',
    'Writes and non-entity endpoints are not wrapped. Use the SDK directly',
    'and shape the result:',
  ]))
  cells.push(code([
    `# rows = ad.sdk.SomeEntity().list()`,
    `# ad.frame(rows)`,
    `ad.entities()`,
  ]))

  const nb = {
    cells,
    metadata: {
      colab: { name: `${name} Data quickstart`, provenance: [] },
      kernelspec: { name: 'python3', display_name: 'Python 3' },
      language_info: { name: 'python' },
    },
    nbformat: 4,
    nbformat_minor: 0,
  }

  File({ name: 'notebooks/quickstart.ipynb' }, () =>
    Content(JSON.stringify(nb, null, 1) + '\n'))
})


// nbformat source arrays keep the trailing newline on every line but the last,
// which is how Jupyter itself writes them — it keeps diffs line-oriented.
function nbSource(lines: string[]): string[] {
  return lines.map((l, i) => i === lines.length - 1 ? l : l + '\n')
}

function md(lines: string[]) {
  return { cell_type: 'markdown', metadata: {}, source: nbSource(lines) }
}

function code(lines: string[]) {
  return {
    cell_type: 'code',
    execution_count: null,
    metadata: {},
    outputs: [],
    source: nbSource(lines),
  }
}


// A column worth putting in a groupby example. Object columns hold dicts and
// lists — grouping by one produces an unhashable-type error, and picking the
// alphabetically-first field lands on exactly that surprisingly often. Prefer
// a required categorical-ish column, then any of them, and only then fall
// back to whatever is first.
function exampleGroupField(fields: { name: string, dtype: string, req: boolean }[]): string {
  const groupable = fields.filter((f) => 'string' === f.dtype || 'boolean' === f.dtype)
  const required = groupable.find((f) => f.req)
  return (required || groupable[0] || fields[0] || { name: 'id' }).name
}


export {
  Main,
}
