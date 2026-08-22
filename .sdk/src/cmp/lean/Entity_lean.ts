import { cmp } from '@voxgig/sdkgen'

// Entities are generic in the Lean target: there is no per-entity generated
// module. Every entity's operations are dispatched by the config-driven
// SdkRuntime (see SdkClient), so this component emits nothing. It exists only
// so the neutral Entity component can resolve a language delegate.
const Entity = cmp(function Entity(_props: any) {})

export { Entity }
