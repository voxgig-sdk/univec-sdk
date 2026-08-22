
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# Maven build output
target/

# Compiled class files
*.class

# Package files
*.jar
*.war

# JVM crash logs
hs_err_pid*
replay_pid*

# IDE / OS
.idea/
.vscode/
*.iml
.DS_Store
`)
  })
})


export {
  Gitignore
}
