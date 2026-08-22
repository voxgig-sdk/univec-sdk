
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# scala-cli build output
.scala-build/
.bsp/
out/

# Compiled class files
*.class

# IDE / OS
.idea/
.vscode/
.metals/
.DS_Store
`)
  })
})


export {
  Gitignore
}
