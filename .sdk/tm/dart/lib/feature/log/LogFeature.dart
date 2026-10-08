// ignore_for_file: non_constant_identifier_names

import '../base/BaseFeature.dart';

// Structured operation logging. Dependency-free: log records are written
// with print (or a caller-supplied `logger` function receiving the record
// map), one line per hook, mirroring the donor log feature's record shape.
class LogFeature extends BaseFeature {
  dynamic _client;
  dynamic _logger;

  LogFeature() {
    version = '0.0.1';
    name = 'log';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];

    if (active) {
      var logger = options['logger'];

      if (null == logger) {
        final level = options['level'] ?? 'info';
        logger = (dynamic record) {
          // ignore: avoid_print
          print('[' +
              level.toString() +
              '] ' +
              (record is Map ? record['hook'].toString() : '') +
              ' ' +
              record.toString());
        };
      }

      _logger = logger;
    }
  }

  @override
  dynamic PostConstruct(dynamic ctx) => _loghook('PostConstruct', ctx);

  @override
  dynamic PostConstructEntity(dynamic ctx) =>
      _loghook('PostConstructEntity', ctx);

  @override
  dynamic SetData(dynamic ctx) => _loghook('SetData', ctx);

  @override
  dynamic GetData(dynamic ctx) => _loghook('GetData', ctx);

  @override
  dynamic GetMatch(dynamic ctx) => _loghook('GetMatch', ctx);

  @override
  dynamic PrePoint(dynamic ctx) => _loghook('PrePoint', ctx);

  @override
  dynamic PreSpec(dynamic ctx) => _loghook('PreSpec', ctx);

  @override
  dynamic PreRequest(dynamic ctx) => _loghook('PreRequest', ctx);

  @override
  dynamic PreResponse(dynamic ctx) => _loghook('PreResponse', ctx);

  @override
  dynamic PreResult(dynamic ctx) => _loghook('PreResult', ctx);

  // A log line leaves the pipeline, so it carries the cleaned record: the
  // spec after auth holds the credential, and a logger prints what it is
  // handed.
  dynamic _loghook(String hook, dynamic ctx) {
    if (null != _logger) {
      final clean = ctx.utility.clean;
      _logger(clean(ctx, {
        'hook': hook,
        'op': null == ctx.op ? null : ctx.op.name,
        'client': null == _client ? null : 'Univec',
        'spec': ctx.spec,
        'ctx': ctx.toJSON(),
      }));
    }
    return null;
  }
}
