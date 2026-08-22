

import { cmp, Content } from '@voxgig/sdkgen'


const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props

  // Public accessor: (<entityname> client data) constructs an entity client.
  // The accessor name is the (lower-case) entity name; the entity namespace is
  // aliased e-<name> in the api ns require.
  Content(`
;; ${entity.Name} accessor: (${entity.name} client data)
(defn ${entity.name} [client data] (e-${entity.name}/make client data))
`)
})


export {
  MainEntity
}
