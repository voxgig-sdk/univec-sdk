
import {
  Content,
  File,
  cmp,
  each,
  omap,
  packageName,
  pkgDescription,
  keywords,
  repoInfo,
  PUBLISHER,
  PUBLISHER_URL,
  packageVersion,
  authorInfo,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
  nom,
} from '@voxgig/apidef'


const Package = cmp(async function Package(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  // WHO WROTE THIS PACKAGE. Per target, falling back to the model-wide value
  // and then to the publisher — so a manifest cannot go on naming Voxgig
  // while the model names someone else, which is exactly what the hardcoded
  // constant here did.
  const author = authorInfo(model, target.name)

  const feature = getModelPath(model, `main.${KIT}.feature`)

  const only = (kind: string, deps: any) =>
    omap(deps, ([k, v]: any) => [v.active && kind === v.kind ? k : undefined, v.version])

  // merge target and feature deps, by kind
  const deps =
    each(feature, (feature: any) =>
      omap(feature.deps?.[target.name], ([k, v]: any) =>
        [v.active ? k : undefined, v]))

      // TODO: sort by version; rules for version choice?
      // TODO: non-node dep kinds
      .reduce((a: any, deps: any) => (each(deps, (dep: any) =>
        a[dep.kind][dep.key$] = dep.version), a),
        {
          prod: only('prod', target.deps),
          peer: only('peer', target.deps),
          dev: only('dev', target.deps),
        })

  const SdkName = nom(model, 'Name')
  const { repoUrl, issuesUrl } = repoInfo(model)

  const pkg = {
    // The ts target publishes the canonical scoped npm name; the js target
    // appends `-js` so the two never collide on npm.
    name: packageName(model, target.name),
    version: packageVersion(model, target.name),
    description: pkgDescription(model, target.name),
    keywords: keywords(model),
    homepage: `${repoUrl}#readme`,
    repository: { type: 'git', url: `git+${repoUrl}.git` },
    bugs: { url: issuesUrl },
    main: `src/${SdkName}SDK.js`,
    type: 'commonjs',

    // What actually ships. Without `files`, `npm publish` packs the test
    // suite and the build scaffolding too. The js target runs from `src`
    // directly (no build step), so that is the whole package.
    files: ['src'],
    scripts: {
      'test': 'node --test \'test/**/*.test.js\'',
      'test-some': 'node --experimental-test-isolation=none ' +
        '--test-name-pattern=\"$TEST_PATTERN\" --test \'test/**/*.test.js\'',
      'test-utility': 'node --test test/utility/*.test.js',

      "clean": "rm -rf node_modules yarn.lock package-lock.json",
      "reset": "npm run clean && npm i && npm test",
    },
    author,

    // TODO: needs to be config
    license: 'MIT',

    dependencies: deps.prod,
    peerDependencies: deps.peer,
    devDependencies: deps.dev,
  }

  File({ name: 'package.json' }, () => {
    Content(JSON.stringify(pkg, null, 2))
  })
})


export {
  Package
}
