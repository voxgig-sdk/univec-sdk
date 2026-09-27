import { Content, File, cmp } from '@voxgig/sdkgen'

const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# Lake build output
.lake/
build/
lake-packages/

# The secrets feature's C stubs and link response file, written by
# \`make ffi\` (see Makefile)
*.o
src/feature/secrets/ffi/link.rsp

# IDE / OS
.idea/
.vscode/
.DS_Store
`)
  })
})

export { Gitignore }
