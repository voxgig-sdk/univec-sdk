
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# C build output
*.o
*.out
*.a
a.out
corpus-scoreboard.json

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
