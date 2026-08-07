
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
    name: packageName(model, 'js'),
    version: `0.0.1`,
    description: pkgDescription(model, target.name),
    keywords: keywords(model),
    homepage: `${repoUrl}#readme`,
    repository: { type: 'git', url: `git+${repoUrl}.git` },
    bugs: { url: issuesUrl },
    main: `src/${SdkName}SDK.js`,
    type: 'commonjs',
    scripts: {
      'test': 'node --test \'test/**/*.test.js\'',
      'test-some': 'node --experimental-test-isolation=none ' +
        '--test-name-pattern=\"$TEST_PATTERN\" --test \'test/**/*.test.js\'',
      'test-utility': 'node --test test/utility/*.test.js',

      "clean": "rm -rf node_modules yarn.lock package-lock.json",
      "reset": "npm run clean && npm i && npm test",
    },
    author: { name: PUBLISHER, url: PUBLISHER_URL },

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
