
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# Build output
bin/
obj/
out/

# Test results
TestResults/
*.trx

# NuGet
*.nupkg
*.snupkg
packages/

# IDE / OS
.vs/
.idea/
.vscode/
*.user
.DS_Store
`)
  })
})


export {
  Gitignore
}
