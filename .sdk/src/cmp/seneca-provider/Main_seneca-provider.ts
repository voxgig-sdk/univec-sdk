import {
  cmp, each,
  File, Content, Copy, Folder,
  entityCollection, entityOps, entityIdField, entityClassName,
  opRequestShape, opParams, ownPoint, entityPath,
  collectDeps, repoInfo, packageName, packageVersion, apiName, envName,
  authorInfo, contributorList, isAuthActive, jsKey, jsProp,
  SdkGenError,
  PUBLISHER, PUBLISHER_URL,
} from '@voxgig/sdkgen'

import {
  KIT,
} from '@voxgig/apidef'

import { Tests, Scripts, Workflow, Readme, Docs } from './Extras_seneca-provider'
import { Gitignore } from './Gitignore_seneca-provider'


// The `seneca-provider` target: a Seneca plugin exposing this API's entities
// as Seneca entities (`provider/<name>/<entity>`), layered on the sibling
// `ts` SDK.
//
// A consumer target in the go-cli / py-data mould — every standard phase is
// off in model/target/seneca-provider.aon and this component emits the
// whole package. It differs from those in one way that shapes everything
// here: it generates into ITS OWN REPO (`output: path`), depends on the SDK
// as a PUBLISHED npm package rather than by path, and therefore carries a
// repo's worth of furniture rather than a subfolder's.
//
// SHAPE OF THE MAPPING
//
// Seneca's store commands are list / load / save / remove. The SDK's are
// list / load / create / update / remove. `save` is the one that is not
// one-to-one: Seneca's convention is that an entity carrying an id is an
// update and one without is a create, so `save` dispatches on `data.id`.
//
// Everything else follows from the model:
//   - which cmds exist at all, from the entity's declared ops;
//   - the required path params of each op, which become argument guards (a
//     nested entity like `moon` under `/planet/{planet_id}/moon` cannot build
//     its URL without the parent id, and an opaque 404 from a half-built URL
//     is a bad error message);
//   - the SDK accessor and entity class names, from the same helpers the ts
//     target uses, so the two cannot drift.


// Seneca store cmd -> the SDK ops it needs. `save` needs BOTH create and
// update; it is emitted when either is present and dispatches on the id.
const CMD_OPS: Record<string, string[]> = {
  list: ['list'],
  load: ['load'],
  save: ['create', 'update'],
  remove: ['remove'],
}


// The required (non-optional) request keys of an op, id first. These are what
// the SDK needs to build the path, so they are what the provider must have
// before it calls.
function requiredKeys(ent: any, opname: string): string[] {
  const idf = entityIdField(ent)
  return opRequestShape(ent, opname).items
    .filter((it: any) => !it.optional)
    .map((it: any) => it.name)
    .sort((a: string, b: string) => (a === idf ? 0 : 1) - (b === idf ? 0 : 1))
}


// The key that addresses ONE record.
//
// `entityIdField` answers whenever the model declares one, which apidef does
// for any entity carrying a field literally named `id` — and it renames an
// `<entity>_id` path param to `id` besides, which is why most APIs never reach
// the fallback.
//
// When it does NOT answer, the record key is the LAST path param of the
// op's own point, in PATH order — a route addresses parents first and the
// record last, by construction. Without this the key was simply unknown,
// so a param named `code` failed the `!== idf` test in opParentKeys and
// was classified as a PARENT — `load$('SAVE20')` threw "coupon load: code
// is required" instead of loading anything, and the entity was treated as
// nested throughout.
//
// opParams(op) is NOT the source here: it alphabetizes params for output
// stability, which loses path order on a 3+-param route — Airtable's
// record (base_id, table_id, record_id) alphabetizes with table_id last,
// so the old `params[params.length - 1]` picked the wrong parent as the
// record's own key. The point's own `parts` still has the true order.
function recordKey(ent: any): string {
  const idf = entityIdField(ent)
  if (null != idf && '' !== idf) {
    return String(idf)
  }

  for (const opname of ['load', 'remove', 'update']) {
    const op = (ent.op || {})[opname]
    if (null == op || 0 === (op.points || []).length) {
      continue
    }

    const canonical = op.points.filter((pt: any) =>
      null == (pt && pt.select && pt.select['$action']))
    const point = ownPoint(0 < canonical.length ? canonical : op.points)
    const parts: string[] = (point && point.parts) || []
    const lastParam = [...parts].reverse().find((p: string) => p.startsWith('{'))

    if (null != lastParam) {
      return lastParam.slice(1, -1)
    }
  }

  return 'id'
}


// The guard function's name. Spec-derived param names are not constrained to
// identifiers — Evervault's `/payments/3ds-sessions/{3ds_session_id}` is the
// standing example — and a name is a DECLARATION here, so it cannot be
// bracket-quoted the way a property access can. Non-identifier characters are
// replaced rather than dropped, so `a-b` and `a_b` cannot collide.
function guardName(e: any, key: string): string {
  return `need_${e.name}_${String(key).replace(/[^A-Za-z0-9_$]/g, '_')}`
    .replace(/^need_(\d)/, 'need__$1')
}


// The parent PATH params of ONE op: `moon`'s load under
// `/planet/{planet_id}/moon/{id}` yields ['planet_id']. These are the keys a
// caller can forget, so each gets a guard.
//
// From opParams — the op's declared path params — NOT from opRequestShape.
// For create/update the latter also returns the request BODY fields, so
// reading it here generated a "planet name is required" guard for every
// writable field on every entity.
function opParentKeys(ent: any, opname: string): string[] {
  const rk = recordKey(ent)
  const op = (ent.op || {})[opname]

  if (null == op) {
    return []
  }

  const seen = new Set<string>()

  for (const p of opParams(op)) {
    const name = String((p as any).name)
    if (false !== (p as any).reqd && name !== rk && name !== 'id') {
      seen.add(name)
    }
  }

  return [...seen].sort()
}


// Every parent key the entity has, across its ACTIVE ops — for the seed data
// and the docs, which describe the entity rather than one call.
//
// `entityOps` and not `Object.keys(ent.op)`: an op the model marks
// `active: false` generates no SDK method, so letting it contribute a key
// here put a mandatory guard for a parameter of a call that does not exist
// onto every cmd that does.
function parentKeys(ent: any): string[] {
  const seen = new Set<string>()

  for (const opname of entityOps(ent)) {
    for (const key of opParentKeys(ent, opname)) {
      seen.add(key)
    }
  }

  return [...seen].sort()
}


// A model field's broad shape, for generating seed data that reads as data.
// The model carries canon strings (`\`$STRING\``), not JS types.
//
// ORDER MATTERS and the tests are substring tests, so the container kinds are
// checked FIRST: a multi-type field's sentinel is the ARRAY
// `['`$ONE`', [members...]]`, and String() flattens it to a comma-joined
// string — so a `$ONE` of string|number matched `includes('NUMBER')` and was
// seeded as a bare number. A union is not a number; it is whatever its first
// member is, and falling back to a string is the safe answer.
//
// `$ARRAY` and `$OBJECT` are in the sentinel vocabulary (see
// helpers/canonType.ts) and used to fall through to 'string', which put
// `tags: 'quick-tags'` into test/quick.js — a type-incorrect body that a
// validating server rejects.
function fieldKind(type: any): string {
  if (Array.isArray(type)) {
    return 'string'
  }

  const t = String(type || '').toUpperCase()

  if (t.includes('ARRAY') || t.includes('LIST')) return 'array'
  if (t.includes('OBJECT') || t.includes('MAP')) return 'object'
  if (t.includes('BOOLEAN')) return 'boolean'
  if (t.includes('NUMBER') || t.includes('INTEGER')) return 'number'

  return 'string'
}


// Which entity a parent path param refers to: `planet_id` -> `planet`, but
// only when an entity of that name actually exists. A key that names no
// entity gets no cross-reference, and the seed falls back to a plain string.
function parentEntityOf(key: string, names: string[]): string {
  const stem = key.replace(/_id$/, '')
  return names.includes(stem) ? stem : ''
}


// The repo this provider is released from — NOT the SDK's. A provider is its
// own package in its own repo, so its manifest's homepage/repository must
// point there; deriving them from `main: kit: repo` sends every link in the
// published package to the SDK instead.
//
// Order: the project's `output: repo`, else the Seneca convention.
function providerRepo(model: any, lower: string, tname: string):
  { url: string, path: string } {
  const host = model?.main?.[KIT]?.repo?.host || 'github.com'
  const declared = model?.main?.[KIT]?.target?.[tname]?.output?.repo
  const path = null != declared && '' !== declared ?
    String(declared) : `senecajs/seneca-${lower}-provider`

  return { url: `https://${host}/${path}`, path }
}


// The provider's published package name: the project's pin when it has one,
// else `@seneca/<name>-provider`. packageName() cannot answer this — its
// derivations are all SDK-shaped (`@<origin>/<slug>-sdk`).
function providerPackage(model: any, lower: string, tname: string): string {
  const declared = model?.main?.[KIT]?.target?.[tname]
    ?.publish?.registry?.package
  return null != declared && '' !== declared ?
    String(declared) : `@seneca/${lower}-provider`
}


const Main = cmp(function Main(props: any) {
  const { target, ctx$ } = props
  const { model } = ctx$

  // HARD REQUIREMENT: this plugin imports the TypeScript SDK. Generating it
  // without `ts` produces a package whose every import fails, so fail at
  // GENERATE time with an actionable message instead.
  const targets = model.main[KIT].target || {}
  if (null == targets.ts) {
    throw new SdkGenError(
      'seneca-provider requires the `ts` target in the same SDK: it imports ' +
      'the TypeScript SDK that `ts` generates. Add it with:\n' +
      '  npm run add-target ts\n' +
      'then regenerate.')
  }

  const Name = model.const.Name                 // Solardemo
  const lower = String(model.const.name)        // solardemo
  const ENV = envName(model)                    // SOLARDEMO
  const sdkClass = `${Name}SDK`                 // SolardemoSDK
  const pluginName = `${Name}Provider`          // SolardemoProvider
  const fileBase = `${lower}-provider`          // solardemo-provider

  // The SDK is a PUBLISHED dependency, not a path: this package lives in its
  // own repo. Its name is whatever the ts target publishes under, pin
  // included, so the two can never disagree.
  // The TypeScript SDK this provider WRAPS — a different target, so it
  // keeps its own name and does not follow this provider's alias.
  const sdkPkg = packageName(model, 'npm')
  const sdkVersion = packageVersion(model, 'ts')

  // UNFILTERED by design — see the AGENTS.md sharp edge: entityCollection is
  // the resolver every component must use (getModelPath rebuilds its container
  // per call, defeating the class-name memo), and it deliberately includes
  // inactive entities because the typed-model emitters need them.
  //
  // Which makes filtering `active` the CALLER's job, and this component was
  // the one consumer target that skipped it — go-cli, go-mcp and py-data all
  // re-filter. The cost: MainEntity_ts emits an accessor only for an ACTIVE
  // entity, so an inactive one produced `this.shared.sdk.Ghost()` in the
  // provider and an `assert.equal(typeof sdk.Ghost, 'function')` in its tests,
  // against a method the SDK does not have.
  const entityColl = entityCollection(model)

  const activeEntities = Object.keys(entityColl).sort()
    .map((key: string) => entityColl[key])
    .filter((ent: any) => false !== ent.active)

  // Entities this provider can serve: those with at least one op that maps to
  // a Seneca store cmd. An entity with no such op would produce an empty cmd
  // map, which seneca-entity treats as a store that answers nothing.
  const entityNames = activeEntities.map((ent: any) => ent.name)

  const entities = activeEntities
    .map((ent: any) => {
      const parents = parentKeys(ent)

      // The parent entity PER KEY. Deriving it from `parents[0]` alone left an
      // entity nested two levels deep with no cross-reference for its outer
      // parents, so their seed values came out as the literal '0'.
      const parentOf: Record<string, string> = {}
      for (const key of parents) {
        parentOf[key] = parentEntityOf(key, entityNames)
      }

      // The parent keys of each op SEPARATELY. The guards used to be the union
      // across all ops, applied to every cmd alike, while the argument handed
      // to the SDK was computed per op — so an entity whose routes are not
      // uniformly nested (a flat `load`, a nested `create`) demanded a
      // parameter its own call would never use.
      const opParents: Record<string, string[]> = {}
      for (const opname of entityOps(ent)) {
        opParents[opname] = opParentKeys(ent, opname)
      }

      return {
        ent,
        name: ent.name,
        // The SDK ACCESSOR on the client (`client.Moon()`), which is the
        // entity's PascalCase name — NOT entityClassName, which is the
        // collision-safe CLASS name the accessor constructs (`MoonEntity`).
        // Calling the class name reads plausibly and fails at runtime with
        // "sdk.MoonEntity is not a function". MainEntity_ts is the authority
        // for this: it declares the method as `${entity.Name}()`.
        acc: ent.Name,
        // The entity's canonical route, used to probe the live server for
        // liveness. Path params are left in place only if the route has
        // them — a collection route (the `list` op's) has none, which is why
        // entityPath prefers it.
        path: entityPath(ent),
        cls: entityClassName(ent, entityColl),
        ops: entityOps(ent),
        idf: entityIdField(ent),
        parents,
        parentOf,
        opParents,
        // The entity the FIRST parent key points at. Kept because the docs and
        // the scripts speak about "the parent" in the singular; anything that
        // must be right per key reads parentOf.
        parentEntity: 0 < parents.length ? parentOf[parents[0]] : '',
        // Required fields only: a seed record has to satisfy the shape the
        // SDK will hand back, and optional noise makes the assertions
        // harder to read.
        //
        // A parent path param is then FORCED IN even when the entity's own
        // schema omits it or marks it optional. A path param is a routing key,
        // not necessarily a response field: when the child's schema left it
        // out the seeded record had no link back to its parent, and the mock's
        // match found nothing — which the nested `load` test reported as a
        // TypeError and the nested `list` test reported as a pass.
        fields: (() => {
          const req = (ent.fields || [])
            .filter((f: any) => false !== f.req)
            .map((f: any) => ({
              name: f.name,
              kind: fieldKind(f.type),
              parentEntity: parentEntityOf(f.name, entityNames),
            }))

          const have = new Set(req.map((f: any) => f.name))

          for (const key of parents) {
            if (!have.has(key)) {
              req.push({
                name: key,
                kind: 'string',
                parentEntity: parentOf[key],
              })
            }
          }

          return req
        })(),
      }
    })
    .map((e: any) => ({
      ...e,
      cmds: Object.keys(CMD_OPS)
        .filter((cmd) => CMD_OPS[cmd].some((op) => e.ops.includes(op))),
    }))
    .filter((e: any) => 0 < e.cmds.length)

  if (0 === entities.length) {
    throw new SdkGenError(
      'seneca-provider: no entity in this model declares a list/load/create/' +
      'update/remove operation, so the plugin would expose no entities at ' +
      'all. Remove the target, or add an entity with CRUD ops.')
  }

  const repo = providerRepo(model, lower, target.name)

  // The companion test server lives in the SDK repo's `app/` and is NOT
  // published, so the only way to reach it is the local checkout. The path
  // back to it is the inverse of this target's own `output: path`, computed
  // once by the external pass — see cmp/ExternalTarget.
  const sdkrel = ctx$.sdkrelpath || '..'

  // Where a live run points — and whether there is anything honest to point
  // it at.
  //
  // NOT simply `servers[0].url`. For an OpenAPI-derived model that is the
  // PRODUCTION host of a third-party API, and everything gated on it aims
  // there: the `describe('live')` block, which `npm test` runs on every CI
  // push on three operating systems; the `serverUp` probe in front of it; and
  // test/quick.js, whose header says "start the companion server first" while
  // BASE silently defaults to production and whose body is a create / update /
  // remove cycle. A live suite that reaches a stranger's API from CI is not a
  // live suite, it is traffic — and unauthenticated traffic at that.
  //
  // So a live base is taken only when it is unambiguously OURS: declared
  // outright by the project, or a loopback address, which no third party can
  // be behind. Anything else leaves live testing ungenerated, which is the
  // honest answer for an API nobody here runs.
  const live = model?.main?.[KIT]?.test?.live || {}
  const servers = (model?.main?.[KIT]?.info?.servers || [])
  const specBase = 0 < servers.length ? String(servers[0].url || '') : ''

  const loopback = (url: string) =>
    /^https?:\/\/(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])([:/]|$)/i.test(url)

  const liveBase = null != live.base && '' !== live.base ? String(live.base) :
    (loopback(specBase) ? specBase : '')

  // Whether the SDK's own repo ships a runnable companion server under
  // `app/`. NOTHING in an API definition says so — it is a property of the
  // sibling project — so it cannot be inferred, and inferring it is what put
  // an unconditional `git clone && cd app && npm install && npm run build`
  // into every generated provider's CI.
  const liveApp = true === live.app || (loopback(specBase) && '' === (live.base || ''))

  const provider = {
    Name, lower, ENV, sdkClass, pluginName, fileBase,
    sdkPkg, sdkVersion, entities,
    repoUrl: repo.url,
    // The SDK's own repo, for pointing at the companion test server which is
    // only distributed in source.
    sdkRepoUrl: repoInfo(model).repoUrl,
    api: apiName(model),
    version: packageVersion(model, target.name),
    sdkrel,
    liveBase,
    liveApp,
    // The sponsor line. @seneca/maintain's `content_readme` check requires
    // the publisher's name in the README, so this is load-bearing rather
    // than decorative — the generated `maintain` test fails without it.
    publisher: PUBLISHER,
    publisherUrl: PUBLISHER_URL,
    // A route with NO path params, so the probe is a plain GET. An entity
    // whose every route is parameterised gives none, and then the probe
    // falls back to the base URL itself.
    probePath: (entities.find((e: any) =>
      '' !== e.path && !e.path.includes('{')) || { path: '' }).path,
    // The provider's OWN published name. Not derived from the SDK slug the
    // way a language target's is — a provider is `@seneca/<name>-provider` —
    // so read the project's pin directly and default to that shape.
    pkgName: providerPackage(model, lower, target.name),
    // Whether this API authenticates at all. Decides if the plugin plumbs a
    // credential: the SDK's auth stage emits nothing for an auth-inactive
    // model and strips the authorization header regardless of options, so
    // plumbing one anyway produces a credential path that cannot work.
    authActive: isAuthActive(model),
  }

  // `.gitignore` is EMITTED rather than copied — npm strips that filename
  // from the tarball, so as a template it reached only checkout users. See
  // Gitignore_seneca-provider. Called before the Copy, as every language
  // target calls its own.
  Gitignore({})

  // Static furniture: LICENSE, CODE_OF_CONDUCT, Makefile, tsfmt.json and
  // both tsconfigs. Same for every provider.
  Copy({
    from: 'tm/' + target.name,
    replace: { ...ctx$.stdrep },
  })

  PackageJson({ provider, target })
  ProviderSource({ provider })
  ProviderDoc({ provider })
  Tests({ provider })
  Scripts({ provider })
  Workflow({ provider })
  Readme({ provider })
  Docs({ provider })
})


// --- package.json -----------------------------------------------------------

const PackageJson = cmp(function PackageJson(props: any) {
  const { provider, target } = props
  const { model } = props.ctx$

  const deps = collectDeps(model, target.name, target.deps, props.ctx$.log)

  // collectDeps returns { name, version, source, raw } — the DECLARED kind
  // (prod/peer/dev) is on `raw`, not hoisted. Reading `d.kind` instead
  // silently yields an empty manifest section, which is how the first cut of
  // this component shipped a package.json with no seneca peers at all.
  //
  // `kind` is a COMMA-SEPARATED LIST, so one dependency can land in more than
  // one manifest section. That is the Seneca plugin convention and not an
  // embellishment: `seneca` is a PEER (the plugin must run inside the host's
  // instance, never its own bundled copy) and also a DEV dependency (the test
  // suite does `require('seneca')` directly, so a bare `npm install` in a
  // clean checkout has to produce it). collectDeps deduplicates by package
  // name and the model's dep map is keyed by name, so the same package cannot
  // be declared twice — the kind has to carry the list instead.
  const dep = (kind: string) => {
    const out: Record<string, string> = {}
    const kinds = (d: any) => String((d.raw && d.raw.kind) || '')
      .split(',').map((s: string) => s.trim()).filter((s: string) => '' !== s)

    for (const d of deps.filter((d: any) => kinds(d).includes(kind))) {
      out[d.name] = d.version
    }
    return out
  }

  // Attribution. Model-driven, because it cannot be derived and because
  // regeneration OVERWRITES the manifest: the hand-written provider this
  // target was modelled on lost its author and both named contributors on the
  // first regeneration, and nothing failed. Unset falls back to the publisher.
  const author = authorInfo(model)
  const contributors = contributorList(model)

  const pkg = {
    name: provider.pkgName,
    version: provider.version,
    main: `dist/${provider.fileBase}.js`,
    type: 'commonjs',
    types: `dist/${provider.fileBase}.d.ts`,
    description:
      `Seneca entity provider for the ${provider.api} API, using the ` +
      `${provider.sdkPkg} SDK.`,
    homepage: provider.repoUrl,
    keywords: ['seneca', provider.lower, `${provider.lower}-provider`,
      provider.publisher.toLowerCase(), 'sdk'],
    author,
    // Omitted entirely when the project names none, rather than emitted as an
    // empty array — npm treats `"contributors": []` as a declaration that
    // there are none, which is a different claim from not having said.
    ...(0 < contributors.length ? { contributors } : {}),
    license: 'MIT',
    repository: { type: 'git', url: `git+${provider.repoUrl}.git` },
    scripts: {
      test: 'node --enable-source-maps --test test/**/*.test.js',
      'test-some':
        'node --enable-source-maps --test-name-pattern="$TEST_PATTERN" ' +
        '--test "test/**/*.test.js"',
      'test-watch': 'node --test --watch test/**/*.test.js',
      watch: 'tsc --build src test -w',
      build: 'tsc --build src test',
      'test-coverage':
        'node --enable-source-maps --experimental-test-coverage --test ' +
        'test/**/*.test.js',
      clean:
        'rm -rf node_modules dist dist-test .tsbuildinfo yarn.lock ' +
        'package-lock.json',
      reset: 'npm run clean && npm i && npm run build && npm test',
      // The Seneca release convention: tag from package.json, push, publish.
      // Generated because a provider is released like every other Seneca
      // plugin, and a maintainer who has to remember the incantation will
      // eventually publish an untested build.
      'repo-tag':
        'REPO_VERSION=`node -e "console.log(require(\'./package\').version)"` ' +
        '&& echo TAG: v$REPO_VERSION && git commit -a -m v$REPO_VERSION ' +
        '&& git push && git tag v$REPO_VERSION && git push --tags;',
      'repo-publish': 'npm run clean && npm i && npm run repo-publish-quick',
      'repo-publish-quick':
        'npm run build && npm run test && npm run repo-tag && ' +
        'npm publish --access public --registry https://registry.npmjs.org',
    },
    // What actually ships. Without `files`, `npm publish` packs the test
    // suite and build output into the tarball.
    files: ['dist', 'src/**/*.ts', 'LICENSE'],
    engines: { node: '>=24' },
    dependencies: {
      // The SDK this plugin wraps, by its PUBLISHED name and version.
      [provider.sdkPkg]: `^${provider.sdkVersion}`,
      ...dep('prod'),
    },
    peerDependencies: dep('peer'),
    devDependencies: dep('dev'),
  }

  File({ name: 'package.json' }, () => {
    Content(JSON.stringify(pkg, null, 2) + '\n')
  })
})


// --- src/<name>-provider.ts -------------------------------------------------

const ProviderSource = cmp(function ProviderSource(props: any) {
  const { provider } = props

  Folder({ name: 'src' }, () => {
    File({ name: `${provider.fileBase}.ts` }, () => {
      Content(`/* Generated by @voxgig/sdkgen. Do not edit. */

const Pkg = require('../package.json')

const { ${provider.sdkClass} } = require('${provider.sdkPkg}')

const SdkPkg = require('${provider.sdkPkg}/package.json')


type ${provider.pluginName}Options = {
  // Options passed straight to the ${provider.sdkClass} constructor,
  // most usefully \`base\` to point at a server.
  sdk?: Record<string, any>

  // Run the SDK in offline test mode (in-memory mock transport).
  test?: boolean

  // Test feature options, e.g. {entity: {${provider.entities[0].name}: {...}}} to
  // seed the mock with data. Only used when \`test\` is true.
  testopts?: Record<string, any>
}


function ${provider.pluginName}(this: any, options: ${provider.pluginName}Options) {
  const seneca: any = this

  const entityBuilder = this.export('provider/entityBuilder')

  seneca.message('sys:provider,provider:${provider.lower},get:info', get_info)

  async function get_info(this: any, _msg: any) {
    return {
      ok: true,
      name: '${provider.lower}',
      version: Pkg.version,
      sdk: {
        name: '${provider.sdkPkg}',
        version: SdkPkg.version,
      },
    }
  }


  // Every SDK operation resolves to an SDK ENTITY rather than raw data (a
  // removed record included: it comes back marked deleted, still holding what
  // it held). Seneca wants plain data, which the entity hands over through
  // data().
  function plain(res: any) {
    return null == res ? res : res.data()
  }


  // Seneca query directives (sort$, limit$, ...) are for the store, not the
  // API, so they must not reach the SDK as match fields.
  function cleanq(q: any) {
    const out: any = {}
    for (const k in (q || {})) {
      if (!k.endsWith('$')) {
        out[k] = q[k]
      }
    }
    return out
  }


  // The SDK throws on any non-2xx. A 404 from a single-item read is an
  // ordinary "not found" answer rather than a failure, so return null and let
  // everything else propagate. SDK errors carry the HTTP status at the top
  // level, so ask them rather than digging into \`result\`.
  async function ornull(action: () => Promise<any>) {
    try {
      return await action()
    }
    catch (e: any) {
      if (true === e?.notFound) {
        return null
      }
      throw e
    }
  }

`)

      // A guard per required parent key. Without it the SDK builds a
      // half-formed URL and the caller gets an opaque 404 instead of being
      // told what they left out.
      const guarded = provider.entities.filter((e: any) => 0 < e.parents.length)
      if (0 < guarded.length) {
        Content(`  // Nested entities cannot build their path without the parent id, so
  // say which key is missing rather than letting the SDK report an opaque
  // 404 on a half-built URL.
`)
        each(guarded, (e: any) => {
          each(e.parents, (key: any) => {
            const k = String(key.val$ ?? key)
            Content(`  function ${guardName(e, k)}(value: any, cmd: string) {
    if (null == value || '' === value) {
      throw new Error(
        '${provider.pkgName}: ${e.name} ' + cmd + ': ${k} is required'
      )
    }
    return value
  }


`)
          })
        })
      }

      // Seneca's own entity key is ALWAYS literally `id` — `load$('x')` sets
      // `q = { id: 'x' }`, and the id of the entity it builds comes off
      // `data.id`. An API that addresses a record by anything else therefore
      // needs translating in both directions, or `load$` requests a record
      // keyed `undefined` and every entity handed back has no id at all — one
      // that cannot then be saved or removed.
      const aliased = provider.entities.filter((e: any) => 'id' !== recordKey(e.ent))
      each(aliased, (e: any) => {
        const rk = recordKey(e.ent)
        Content(`  // This API keys a ${e.name} by \`${rk}\`, Seneca by \`id\`. Carry the
  // API's key across so the Seneca entity has one.
  function id_${e.name}(data: any) {
    if (null != data && null == data.id) {
      data.id = ${jsProp('data', rk)}
    }
    return data
  }


`)
      })

      // The cmd map, declared up front so every action is attached to a
      // shape seneca-entity can read before the actions are defined.
      Content(`  const entity: any = {
`)
      each(provider.entities, (e: any) => {
        Content(`    ${e.name}: {
      cmd: {
`)
        each(e.cmds, (cmd: any) => {
          Content(`        ${String(cmd.val$ ?? cmd)}: { action: (undefined as any) },
`)
        })
        Content(`      },
    },

`)
      })
      Content(`  }

`)

      each(provider.entities, (e: any) => {
        // The guard set is PER OP, not the union across the entity's ops. An
        // entity whose routes are not uniformly nested — a flat `load`, a
        // nested `create` — used to demand the parent id on the flat call too,
        // an argument its own SDK request would then never use.
        //
        // `save` guards the union of create's and update's keys: one action
        // serves both and dispatches at runtime, so it cannot know which set
        // applies until it has the data.
        const guard = (cmd: string, src: string) => {
          const keys = 'save' === cmd ?
            [...new Set([...(e.opParents.create || []), ...(e.opParents.update || [])])].sort() :
            (e.opParents[cmd] || [])

          return keys
            .map((k: string) =>
              `      ${guardName(e, k)}(${jsProp(src, k)}, '${cmd}')\n`)
            .join('')
        }

        // Reading the record's own key off the Seneca query, which always
        // spells it `id`, and every other required key off its own name.
        const rk = recordKey(e.ent)
        const sdkArg = (opname: string) => {
          const keys = requiredKeys(e.ent, opname)
          if (0 === keys.length) {
            return '{}'
          }
          return `{ ${keys.map((k: string) =>
            `${jsKey(k)}: ${jsProp('q', k === rk ? 'id' : k)}`).join(', ')} }`
        }

        // The data hop, plus the id alias when the API keys the record by
        // something other than `id`.
        const out = (expr: string) =>
          'id' === rk ? `plain(${expr})` : `id_${e.name}(plain(${expr}))`

        if (e.cmds.includes('list')) {
          Content(`
  entity.${e.name}.cmd.list.action =
    async function list_${e.name}(this: any, entize: any, msg: any) {
      const q = cleanq(msg.q)
${guard('list', 'q')}      const list = await this.shared.sdk.${e.acc}().list(q)
      return list.map((data: any) => entize(${out('data')}))
    }

`)
        }

        if (e.cmds.includes('load')) {
          Content(`
  entity.${e.name}.cmd.load.action =
    async function load_${e.name}(this: any, entize: any, msg: any) {
      const q = cleanq(msg.q)
${guard('load', 'q')}      const res = await ornull(() => this.shared.sdk.${e.acc}().load(${sdkArg('load')}))
      return null == res ? null : entize(${out('res')})
    }

`)
        }

        if (e.cmds.includes('save')) {
          const hasCreate = e.ops.includes('create')
          const hasUpdate = e.ops.includes('update')

          // Dispatch on the SENECA key. The record arriving here is a Seneca
          // entity's data, so its id lives at `id` whatever the API calls it —
          // dispatching on the API's key sent every save to `create`, leaving
          // update unreachable.
          const body = hasCreate && hasUpdate
            ? `      const res = null == data.id
        ? await sdk.${e.acc}().create(data)
        : await sdk.${e.acc}().update(data)`
            : hasCreate
              ? `      const res = await sdk.${e.acc}().create(data)`
              : `      const res = await sdk.${e.acc}().update(data)`

          // ... and hand the API back its own key, which Seneca does not know
          // to send.
          const alias = 'id' === rk ? '' :
            `
      // This API keys a ${e.name} by \`${rk}\`; Seneca carries it as \`id\`.
      if (null == ${jsProp('data', rk)} && null != data.id) {
        ${jsProp('data', rk)} = data.id
      }
`

          Content(`
  entity.${e.name}.cmd.save.action =
    async function save_${e.name}(this: any, entize: any, msg: any) {
      const data = msg.ent.data$(false)
${guard('save', 'data')}${alias}      const sdk = this.shared.sdk

${body}

      return entize(${out('res')})
    }

`)
        }

        if (e.cmds.includes('remove')) {
          Content(`
  entity.${e.name}.cmd.remove.action =
    async function remove_${e.name}(this: any, _entize: any, msg: any) {
      const q = cleanq(msg.q)
${guard('remove', 'q')}      await ornull(() => this.shared.sdk.${e.acc}().remove(${sdkArg('remove')}))
      return null
    }

`)
        }
      })

      Content(`
  entityBuilder(this, {
    provider: {
      name: '${provider.lower}',
    },
    entity
  })


  seneca.prepare(async function(this: any) {
    const sdkopts: any = Object.assign({}, options.sdk)
${provider.authActive ? `
    // The provider convention carries credentials, so honour an \`apikey\`
    // when one is configured and stay quiet when it is not.
    const res = await this.post('sys:provider,get:keymap,provider:${provider.lower}')
    const apikey = res?.keymap?.apikey?.value

    // Hand the credential to the SDK as \`apikey\`, NOT as an authorization
    // HEADER. The SDK's own auth stage owns that header: it reads
    // \`options.apikey\`, and on every path where it finds none it DELETES
    // \`authorization\` before the request goes out. A provider that set the
    // header itself was therefore never authenticated — the SDK stripped the
    // very thing it had just written, on every call, silently. The SDK also
    // owns the scheme prefix, which is resolved from the API definition
    // rather than assumed to be \`Bearer\`.
    if (null != apikey && '' !== apikey) {
      sdkopts.apikey = apikey
    }
` : `
    // This API declares no authentication, so no credential is plumbed. The
    // SDK's auth stage emits nothing for an auth-inactive model and deletes
    // any \`authorization\` header regardless of options, so a keymap lookup
    // here would read a key that could not reach the wire — which is what the
    // first version of this target did.
`}
    this.shared.sdk = options.test
      ? ${provider.sdkClass}.test(options.testopts || {}, sdkopts)
      : new ${provider.sdkClass}(sdkopts)
  })


  return {
    exports: {
      sdk: () => this.shared.sdk,
    },
  }
}


// Default options.
const defaults: ${provider.pluginName}Options = {
  sdk: {},
  test: false,
  testopts: {},
}

Object.assign(${provider.pluginName}, { defaults })

export default ${provider.pluginName}

if ('undefined' !== typeof module) {
  module.exports = ${provider.pluginName}
}
`)
    })
  })
})


// --- src/<Name>Provider-doc.ts ----------------------------------------------

const ProviderDoc = cmp(function ProviderDoc(props: any) {
  const { provider } = props

  Folder({ name: 'src' }, () => {
    File({ name: `${provider.pluginName}-doc.ts` }, () => {
      Content(`/* Generated by @voxgig/sdkgen. Do not edit. */


const messages = {
  get_info: {
    desc: 'Get information about the ${provider.api} SDK.',
  },
}


const sections = {
  intro: {
    path: '../provider/doc/intro.md'
  }
}

const docs = {
  sections,
  messages
}

export default docs


if ('undefined' !== typeof module) {
  module.exports = docs
}
`)
    })
  })
})


export {
  Main,
  recordKey,
}
