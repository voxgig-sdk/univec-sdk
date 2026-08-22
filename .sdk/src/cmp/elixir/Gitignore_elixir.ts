
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


const Gitignore = cmp(function Gitignore(_props: any) {
  File({ name: '.gitignore' }, () => {
    Content(`/_build/
/cover/
/deps/
/doc/
/.fetch
erl_crash.dump
*.ez
*.beam
/config/*.secret.exs
.elixir_ls/
`)
  })
})


export {
  Gitignore
}
