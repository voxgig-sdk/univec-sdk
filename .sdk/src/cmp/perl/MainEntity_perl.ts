

import { cmp, Content, entityClassName, entityCollection } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  // Return the collision-free class (entityClassName); the accessor METHOD
  // name (entity.Name) is unchanged so callers still write $client->{Name}.
  const cls = entityClassName(entity, entityCollection(model))

  Content(`
# Canonical facade: $client->${entity.Name}->list / ->load({ 'id' => ... })
sub ${entity.Name} {
  my ($self, $data) = @_;
  require(Cwd::abs_path("$DIR/../entity/${entity.name}_entity.pm"));
  return ${cls}->new($self, $data);
}

`)

})


export {
  MainEntity
}
