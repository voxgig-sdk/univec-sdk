import 'GraphqlUtility.dart';
import '../Spec.dart';

import 'ErrUtility.dart';

// Create request specification.
dynamic makeSpec(dynamic ctx) {
  if (null != ctx.out['spec']) {
    return ctx.spec = ctx.out['spec'];
  }

  final point = ctx.point;
  final options = ctx.options;
  final utility = ctx.utility;

  final prepareMethod = utility.prepareMethod;
  final prepareParams = utility.prepareParams;
  final prepareQuery = utility.prepareQuery;
  final prepareHeaders = utility.prepareHeaders;
  final prepareBody = utility.prepareBody;
  final preparePath = utility.preparePath;
  final prepareAuth = utility.prepareAuth;

  ctx.spec = Spec({
    'base': options['base'], // string, URL endpoint base prefix,
    'prefix': options['prefix'],
    'parts': point.parts,
    'suffix': options['suffix'],
    'step': 'start',
  });

  ctx.spec.method = prepareMethod(ctx);

  final allowmethod = (options['allow']?['method'] ?? '').toString();
  if (!allowmethod.contains(ctx.spec.method.toString())) {
    return ctx.error(
        'spec_method_allow',
        'Method "' +
            ctx.spec.method.toString() +
            '" not allowed by SDK option allow.method value: "' +
            allowmethod +
            '"');
  }

  ctx.spec.params = prepareParams(ctx);
  ctx.spec.query = prepareQuery(ctx);
  ctx.spec.headers = prepareHeaders(ctx);

  if ('graphql' == point.kind) {
    // GraphQL addresses one endpoint: no path parts, no query string, and
    // the body carries the operation. prepareBody is skipped deliberately
    // — it only emits a body for data-input ops, whereas every GraphQL op
    // posts one, including load/list/remove.
    ctx.spec.body = utility.graphqlBody(ctx);
    ctx.spec.path = '';
    // prepareQuery already copied the op's match arguments into the query
    // string. Those same values are bound as operation variables, so
    // leaving them would send /graphql?id=i1.
    ctx.spec.query = <String, dynamic>{};
    ctx.spec.headers['content-type'] = graphqlContentType;
  } else {
    ctx.spec.body = prepareBody(ctx);
    ctx.spec.path = preparePath(ctx);
  }

  if (null != ctx.ctrl['explain']) {
    ctx.ctrl['explain']['spec'] = ctx.spec;
  }

  final spec = prepareAuth(ctx);

  if (!iserr(spec)) {
    ctx.spec = spec;
  }

  return spec;
}
