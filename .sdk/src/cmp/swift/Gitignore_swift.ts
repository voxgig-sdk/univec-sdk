
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# Build output
.build/
*.o
*.swiftmodule

# SwiftPM
Package.resolved

# IDE / OS
.swiftpm/
.idea/
.vscode/
*.xcodeproj
.DS_Store
`)
  })
})


export {
  Gitignore
}
