
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# Build output
test/*.out
*.o
*.out
# The gated secrets feature's vendored archive (tm/cpp/Makefile)
*.a

# Struct-corpus run report (written by test/struct_corpus_test.cpp)
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
