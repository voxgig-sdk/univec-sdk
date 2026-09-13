import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# Haskell build output
.hsbuild/
dist-newstyle/
*.hi
*.o

# IDE / OS
.idea/
.vscode/
.DS_Store
`)
  })
})


export {
  Gitignore
}
