// ignore_for_file: unused_import, unused_local_variable, non_constant_identifier_names

import 'dart:convert';
import 'dart:io';

import '../../harness.dart';
import '../../utility.dart';

import '../../../lib/ProjectNameSDK.dart';
import '../../../lib/utility/voxgig_struct.dart' as vs;

void tests() {
  describe('EntityNameEntity', () {
    test('instance', (t) async {
      final testsdk = ProjectNameSDK.test();
      final ent = testsdk.EntityName();
      ok(null != ent);
    });

    // <[SLOT:stream]>

    test('basic', (t) async {
      // <[SLOT:basic]>
    });
  });
}

// <[SLOT:basicSetup]>
