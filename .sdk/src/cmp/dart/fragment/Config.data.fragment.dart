import 'dart:convert';

import 'feature/base/BaseFeature.dart';
// #ImportFeatures

// ignore: non_constant_identifier_names
final Map<String, BaseFeature Function()> FEATURE_CLASS = {
  // #FeatureClasses
};

// THE API MODEL, EMBEDDED AS DATA (sdkgen rung L1).
//
// The literal form of this file declares the whole model as nested map
// literals. For a large API that is megabytes of source the Dart analyzer and
// compiler must parse and type every node of, on every build, and that the VM
// must build entry by entry on every load.
//
// As a single string constant it is one token, and `jsonDecode` builds the map
// far faster than the equivalent literal.
//
// Emitted only above a size threshold, or when `main.kit.config.repr` pins it:
// for a small model the literal is smaller, loads no slower, and is far easier
// to read when debugging.
const String _CONFIG_DATA = 'CONFIGJSON';

class Config {
  // ONE decode per constructed Config, and each instance owns the maps it
  // decoded. The literal representation builds fresh maps in every field
  // initialiser, so a caller that constructs a second Config and mutates it
  // does not touch the first - and `Config` is exported by Main.fragment.dart,
  // so callers really can construct one.
  //
  // Sharing a single top-level parsed map would have been cheaper and was the
  // first attempt; it made `Config().options['x'] = 1` mutate the `config`
  // singleton every SDK client reads. Decoding per instance costs about what
  // building the literal per instance cost, and the rung's win is untouched:
  // L1 is about what the COMPILER has to walk, not what happens at load.
  Config() : this._(jsonDecode(_CONFIG_DATA) as Map<String, dynamic>);

  Config._(Map<String, dynamic> data)
      : main = data['main'] as Map<String, dynamic>,
        feature = data['feature'] as Map<String, dynamic>,
        options = data['options'] as Map<String, dynamic>,
        entity = data['entity'] as Map<String, dynamic>;

  BaseFeature makeFeature(String fn) {
    final fc = FEATURE_CLASS[fn];
    if (null == fc) {
      // TODO: errors etc
      throw StateError('Unknown feature: ' + fn);
    }
    return fc();
  }

  // False for a feature added at runtime via options.extend (station's
  // adopt path) - the constructor uses this to skip makeFeature for names
  // no generated class backs.
  bool hasFeature(String fn) => null != FEATURE_CLASS[fn];

  // The same fields the literal declares - same names, same types, same
  // finalness - so callers cannot tell which representation they were given.
  final Map<String, dynamic> main;

  final Map<String, dynamic> feature;

  final Map<String, dynamic> options;

  final Map<String, dynamic> entity;

  // The pipeline context carries the config as a plain map.
  Map<String, dynamic> toMap() => <String, dynamic>{
        'main': main,
        'feature': feature,
        'options': options,
        'entity': entity,
      };
}

final config = Config();
