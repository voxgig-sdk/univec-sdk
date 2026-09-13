
import {
  cmp,
} from '@voxgig/sdkgen'


// C has no package manifest — the build is driven by the template Makefile
// (tm/c/Makefile, copied verbatim). Package is a no-op for the C target,
// kept so the Main component can call it uniformly across targets.
//
// This is also why the secrets feature's build model is not emitted from
// here, unlike Package_rust's rustls dependency table or Package_swift's
// targets: the Makefile is feature-agnostic (a trimmed template tree must
// name no feature) and `-include`s a GENERATED feature/<name>/kinds.mk that
// Config_c emits only when the model activates the feature for this
// target - the vendored payload to compile, the suite to run, and the
// plugin layer with its OpenSSL and libcurl only when a plugin group is
// active. Nothing here has to restate the model's choice, so nothing here
// can drift from it.
const Package = cmp(async function Package(_props: any) {
  // intentionally empty
})


export {
  Package
}
