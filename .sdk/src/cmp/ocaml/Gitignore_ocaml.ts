
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


const Gitignore = cmp(async function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`# OCaml build output
*.cmi
*.cmo
*.cmx
*.cma
*.cmxa
*.o
*.a
a.out
run_sdk_test
run_struct_corpus

# dune (unused; the build is stock ocamlc via the Makefile)
_build/

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
