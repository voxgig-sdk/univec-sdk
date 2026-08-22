// ignore_for_file: unused_import, unused_local_variable, non_constant_identifier_names

import 'dart:convert';

import '../../harness.dart';
import '../../utility.dart';

import '../../../lib/ProjectNameSDK.dart';

void tests() {
  describe('EntityNameDirect', () {
    test('direct-exists', (t) async {
      final sdk = ProjectNameSDK({
        'system': {
          'fetch': (dynamic url, dynamic init) async => <String, dynamic>{}
        }
      });
      ok(null != sdk);
    });

    // <[SLOT:direct]>
  });
}

// <[SLOT:directSetup]>
