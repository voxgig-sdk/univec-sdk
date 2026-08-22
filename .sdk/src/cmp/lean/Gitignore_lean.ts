import { Content, File, cmp } from '@voxgig/sdkgen'

const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# Lake build output
.lake/
build/
lake-packages/

# IDE / OS
.idea/
.vscode/
.DS_Store
`)
  })
})

export { Gitignore }
