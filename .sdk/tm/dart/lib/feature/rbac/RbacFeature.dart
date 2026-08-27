// ignore_for_file: non_constant_identifier_names

import '../../utility/voxgig_struct.dart' as vs;

import '../base/BaseFeature.dart';

// Client-side role/permission enforcement. Before an operation resolves its
// endpoint, the required permission for that entity+operation is checked
// against the permissions the client holds; a disallowed call is
// short-circuited with an `rbac_denied` error and never touches the
// network. Required permissions come from `rules` (keyed by
// `<entity>.<op>`, `<op>`, or `*`); the default when no rule matches is
// controlled by `deny` (default: allow when unspecified). Held permissions
// are the `permissions` list (a `*` grants everything).
class RbacFeature extends BaseFeature {
  dynamic _client;
  final Map<String, bool> _granted = {};

  RbacFeature() {
    version = '0.0.1';
    name = 'rbac';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];

    _granted.clear();
    final perms = options['permissions'] ?? [];
    for (final p in perms) {
      _granted[p.toString()] = true;
    }
    return null;
  }

  @override
  dynamic PrePoint(dynamic ctx) {
    if (!active) {
      return null;
    }

    final required = _required(ctx);
    if (null == required) {
      // No rule: honour the default policy.
      if (true == options['deny']) {
        return _reject(ctx, '<default-deny>');
      }
      return null;
    }

    if (true == _granted['*'] || true == _granted[required]) {
      _track(ctx, required, true);
      return null;
    }

    return _reject(ctx, required);
  }

  String? _required(dynamic ctx) {
    final rules = options['rules'] ?? {};
    final entity = _entname(ctx.entity) != ''
        ? _entname(ctx.entity)
        : (null == ctx.op ? '' : (ctx.op.entity ?? '')).toString();
    final opname = (null == ctx.op ? '' : (ctx.op.name ?? '')).toString();

    if (null != vs.getprop(rules, entity + '.' + opname)) {
      return vs.getprop(rules, entity + '.' + opname).toString();
    }
    if (null != vs.getprop(rules, opname)) {
      return vs.getprop(rules, opname).toString();
    }
    if (null != vs.getprop(rules, '*')) {
      return vs.getprop(rules, '*').toString();
    }
    return null;
  }

  dynamic _reject(dynamic ctx, String required) {
    _track(ctx, required, false);
    final err = ctx.error(
        'rbac_denied',
        'Permission "' +
            required +
            '" required for operation "' +
            (null == ctx.op ? '?' : (ctx.op.name ?? '?')).toString() +
            '"');
    // Short-circuit endpoint resolution; the pipeline surfaces this error.
    ctx.out['point'] = err;
    return err;
  }

  void _track(dynamic ctx, String required, bool allowed) {
    final track = _client.track;
    if (null == track['rbac']) {
      track['rbac'] = <String, dynamic>{'allowed': 0, 'denied': 0, 'last': null};
    }
    track['rbac'][allowed ? 'allowed' : 'denied']++;
    track['rbac']['last'] = <String, dynamic>{
      'required': required,
      'allowed': allowed,
      'op': null == ctx.op ? null : ctx.op.name,
    };
  }

  String _entname(dynamic ent) {
    if (null == ent) {
      return '';
    }
    if (ent is Map) {
      return (vs.getprop(ent, 'name', '') ?? '').toString();
    }
    try {
      return (ent.name ?? '').toString();
    } catch (_e) {
      return '';
    }
  }
}
