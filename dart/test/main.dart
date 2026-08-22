// Univec SDK test suite entry. GENERATED — do not edit.

import 'dart:io';

import 'harness.dart' as harness;

import 'exists_test.dart' as exists_test;
import 'struct_test.dart' as struct_test;
import 'primary_test.dart' as primary_test;
import 'pipeline_test.dart' as pipeline_test;
import 'feature_test.dart' as feature_test;
import 'netsim_test.dart' as netsim_test;
import 'custom_test.dart' as custom_test;
import 'readme_examples_test.dart' as readme_examples_test;
import 'entity/convert/ConvertEntity_test.dart' as convert_entity_test;
import 'entity/embed/EmbedEntity_test.dart' as embed_entity_test;
import 'entity/ephemeral_key/EphemeralKeyEntity_test.dart' as ephemeral_key_entity_test;
import 'entity/model/ModelEntity_test.dart' as model_entity_test;
import 'entity/model/ModelDirect_test.dart' as model_direct_test;

Future<void> main() async {
  exists_test.tests();
  struct_test.tests();
  primary_test.tests();
  pipeline_test.tests();
  feature_test.tests();
  netsim_test.tests();
  custom_test.tests();
  readme_examples_test.tests();
  convert_entity_test.tests();
  embed_entity_test.tests();
  ephemeral_key_entity_test.tests();
  model_entity_test.tests();
  model_direct_test.tests();

  final failed = await harness.runAll();
  if (0 < failed) {
    exitCode = 1;
  }
}
