import 'dart:async';

Future<dynamic> makeResponse(dynamic ctx) async {
  // PreResponse feature hook has already provided a result.
  if (null != ctx.out['response']) {
    return ctx.out['response'];
  }

  final utility = ctx.utility;
  final resultBasic = utility.resultBasic;
  final resultHeaders = utility.resultHeaders;
  final resultBody = utility.resultBody;
  final transformResponse = utility.transformResponse;

  final spec = ctx.spec;
  final result = ctx.result;
  final response = ctx.response;

  if (null == spec) {
    return ctx.error(
        'response_no_spec', 'Expected context spec property to be defined.');
  }

  if (null == response) {
    return ctx.error('response_no_response',
        'Expected context response property to be defined.');
  }

  if (null == result) {
    return ctx.error('response_no_result',
        'Expected context result property to be defined.');
  }

  spec.step = 'response';

  try {
    resultBasic(ctx);
    resultHeaders(ctx);
    await Future.value(resultBody(ctx));

    // GraphQL reports failures as a top-level `errors` array under HTTP
    // 200, so resultBasic's status check never sees them. Lift them here,
    // before the response transform tries to unwrap data that is not there.
    utility.graphqlErrors(ctx);
    transformResponse(ctx);

    if (null == result.err) {
      result.ok = true;
    }
  } catch (err) {
    result.err = err;
  }

  if (null != ctx.ctrl['explain']) {
    ctx.ctrl['explain']['result'] = result;
  }

  return response;
}
