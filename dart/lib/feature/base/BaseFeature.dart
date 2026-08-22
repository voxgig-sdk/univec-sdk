// Base feature class implementing every pipeline hook as a no-op.
// Features subclass this and override the hooks they need. Hook dispatch is
// by name (see FeatureHookUtility), routed through `invokeHook` since Dart
// has no dynamic property access.

// ignore_for_file: non_constant_identifier_names

class BaseFeature {
  String version = '0.0.1';
  String name = 'base';
  bool active = true;

  // Feature options as passed to init (used by featureAdd ordering).
  Map<String, dynamic> options = {};

  dynamic init(dynamic ctx, dynamic opts) {}

  dynamic PostConstruct(dynamic ctx) {}

  dynamic PostConstructEntity(dynamic ctx) {}

  dynamic SetData(dynamic ctx) {}

  dynamic GetData(dynamic ctx) {}

  dynamic SetMatch(dynamic ctx) {}

  dynamic GetMatch(dynamic ctx) {}

  dynamic PrePoint(dynamic ctx) {}

  dynamic PreSpec(dynamic ctx) {}

  dynamic PreRequest(dynamic ctx) {}

  dynamic PreResponse(dynamic ctx) {}

  dynamic PreResult(dynamic ctx) {}

  dynamic PreDone(dynamic ctx) {}

  dynamic PreUnexpected(dynamic ctx) {}

  dynamic invokeHook(String hook, dynamic ctx) {
    switch (hook) {
      case 'PostConstruct':
        return PostConstruct(ctx);
      case 'PostConstructEntity':
        return PostConstructEntity(ctx);
      case 'SetData':
        return SetData(ctx);
      case 'GetData':
        return GetData(ctx);
      case 'SetMatch':
        return SetMatch(ctx);
      case 'GetMatch':
        return GetMatch(ctx);
      case 'PrePoint':
        return PrePoint(ctx);
      case 'PreSpec':
        return PreSpec(ctx);
      case 'PreRequest':
        return PreRequest(ctx);
      case 'PreResponse':
        return PreResponse(ctx);
      case 'PreResult':
        return PreResult(ctx);
      case 'PreDone':
        return PreDone(ctx);
      case 'PreUnexpected':
        return PreUnexpected(ctx);
      default:
        return null;
    }
  }
}
