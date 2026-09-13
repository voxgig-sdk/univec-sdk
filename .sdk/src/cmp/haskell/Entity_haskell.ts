import { cmp } from '@voxgig/sdkgen'


// Entities are generic in the Haskell target: there is no per-entity
// generated module. Every entity is created by the config-driven
// F.makeEntity (see SdkClient), so this component emits nothing. It exists
// only so the neutral Entity component can resolve a language delegate.
const Entity = cmp(function Entity(_props: any) {})


export {
  Entity
}
