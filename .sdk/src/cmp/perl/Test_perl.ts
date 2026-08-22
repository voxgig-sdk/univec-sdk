
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, File, Content, entityCollection } from '@voxgig/sdkgen'


import { TestEntity } from './TestEntity_perl'
import { TestDirect } from './TestDirect_perl'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_perl'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  Folder({ name: 't' }, () => {

    // Generate exists test
    File({ name: 'exists.t' }, () => {
      Content(`#!perl
# ${model.const.Name} SDK exists test

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use ${model.const.Name}SDK;

my $testsdk = ${model.const.Name}SDK->test(undef, undef);
ok(defined $testsdk, 'create test sdk');

done_testing();
`)
    })

    const entity = each(entityCollection(model))
      .filter((e: any) => false !== e.active)

    each(entity, (entity: ModelEntity) => {
      TestEntity({ target, entity })
      TestDirect({ target, entity })
    })

    // README example snippet gate (syntax + offline test-mode run).
    ReadmeExamplesTest({ target })
  })
})


export {
  Test
}
