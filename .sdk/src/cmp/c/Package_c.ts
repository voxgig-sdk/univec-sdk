
import {
  cmp,
} from '@voxgig/sdkgen'


// C has no package manifest — the build is driven by the template Makefile
// (copied verbatim). Package is a no-op for the C target, kept so the Main
// component can call it uniformly across targets.
const Package = cmp(async function Package(_props: any) {
  // intentionally empty
})


export {
  Package
}
