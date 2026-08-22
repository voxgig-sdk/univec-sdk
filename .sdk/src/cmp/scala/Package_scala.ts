
import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


// Emits the scala-cli project config (project.scala). The generated SDK is a
// plain-source scala-cli project: no sbt/mill build, no third-party runtime
// dependencies (struct + JSON are vendored, HTTP is the JDK HttpClient).
const Package = cmp(async function Package(_props: any) {
  File({ name: 'project.scala' }, () => {
    Content(`//> using scala "3.7.3"
`)
  })
})


export {
  Package
}
