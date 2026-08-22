
import {
  cmp,
} from '@voxgig/sdkgen'


// The C++ target ships a header-only SDK built by the tm/cpp Makefile (copied
// verbatim); there is no package manifest to generate (unlike pom.xml /
// Cargo.toml / go.mod). This component is a no-op kept for parity with the
// other targets' Main -> Package call.
const Package = cmp(async function Package(_props: any) {
})


export {
  Package
}
