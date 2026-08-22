
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# Gradle build output
.gradle/
build/

# Compiled class files
*.class

# Package files
*.jar
*.war

# Kotlin
.kotlin/

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
