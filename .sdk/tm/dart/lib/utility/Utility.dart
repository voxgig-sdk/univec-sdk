import 'CleanUtility.dart' as u;
import 'DoneUtility.dart' as u;
import 'MakeErrorUtility.dart' as u;
import 'FeatureAddUtility.dart' as u;
import 'FeatureHookUtility.dart' as u;
import 'FeatureInitUtility.dart' as u;
import 'FetcherUtility.dart' as u;
import 'MakeFetchDefUtility.dart' as u;
import 'MakeContextUtility.dart' as u;
import 'MakeOptionsUtility.dart' as u;
import 'MakeRequestUtility.dart' as u;
import 'MakeResponseUtility.dart' as u;
import 'MakeResultUtility.dart' as u;
import 'MakePointUtility.dart' as u;
import 'MakeSpecUtility.dart' as u;
import 'MakeUrlUtility.dart' as u;
import 'ParamUtility.dart' as u;
import 'PrepareAuthUtility.dart' as u;
import 'PrepareBodyUtility.dart' as u;
import 'PrepareHeadersUtility.dart' as u;
import 'PrepareMethodUtility.dart' as u;
import 'PrepareParamsUtility.dart' as u;
import 'PreparePathUtility.dart' as u;
import 'PrepareQueryUtility.dart' as u;
import 'ResultBasicUtility.dart' as u;
import 'ResultBodyUtility.dart' as u;
import 'ResultHeadersUtility.dart' as u;
import 'TransformRequestUtility.dart' as u;
import 'TransformResponseUtility.dart' as u;

import 'GraphqlUtility.dart' as u;
import 'StructUtility.dart';

class Utility {
  dynamic clean = u.clean;
  dynamic done = u.done;
  dynamic makeError = u.makeError;
  dynamic featureAdd = u.featureAdd;
  dynamic featureHook = u.featureHook;
  dynamic featureInit = u.featureInit;
  dynamic fetcher = u.fetcher;
  dynamic makeFetchDef = u.makeFetchDef;
  dynamic makeContext = u.makeContext;
  dynamic makeOptions = u.makeOptions;
  dynamic makeRequest = u.makeRequest;
  dynamic makeResponse = u.makeResponse;
  dynamic makeResult = u.makeResult;
  dynamic makePoint = u.makePoint;
  dynamic makeSpec = u.makeSpec;
  dynamic makeUrl = u.makeUrl;
  dynamic param = u.param;
  dynamic prepareAuth = u.prepareAuth;
  dynamic prepareBody = u.prepareBody;
  dynamic prepareHeaders = u.prepareHeaders;
  dynamic prepareMethod = u.prepareMethod;
  dynamic prepareParams = u.prepareParams;
  dynamic preparePath = u.preparePath;
  dynamic prepareQuery = u.prepareQuery;
  dynamic graphqlBody = u.graphqlBody;
  dynamic graphqlErrors = u.graphqlErrors;
  dynamic resultBasic = u.resultBasic;
  dynamic resultBody = u.resultBody;
  dynamic resultHeaders = u.resultHeaders;
  dynamic transformRequest = u.transformRequest;
  dynamic transformResponse = u.transformResponse;

  final StructUtility struct = StructUtility();

  // Custom utilities injected via options.utility that do not override a
  // standard member (see makeOptions).
  final Map<String, dynamic> custom = {};

  // Assign a utility function by name; unknown names land in `custom`.
  void setUtility(String name, dynamic fn) {
    switch (name) {
      case 'clean':
        clean = fn;
        break;
      case 'done':
        done = fn;
        break;
      case 'makeError':
        makeError = fn;
        break;
      case 'featureAdd':
        featureAdd = fn;
        break;
      case 'featureHook':
        featureHook = fn;
        break;
      case 'featureInit':
        featureInit = fn;
        break;
      case 'fetcher':
        fetcher = fn;
        break;
      case 'makeFetchDef':
        makeFetchDef = fn;
        break;
      case 'makeContext':
        makeContext = fn;
        break;
      case 'makeOptions':
        makeOptions = fn;
        break;
      case 'makeRequest':
        makeRequest = fn;
        break;
      case 'makeResponse':
        makeResponse = fn;
        break;
      case 'makeResult':
        makeResult = fn;
        break;
      case 'makePoint':
        makePoint = fn;
        break;
      case 'makeSpec':
        makeSpec = fn;
        break;
      case 'makeUrl':
        makeUrl = fn;
        break;
      case 'param':
        param = fn;
        break;
      case 'prepareAuth':
        prepareAuth = fn;
        break;
      case 'prepareBody':
        prepareBody = fn;
        break;
      case 'prepareHeaders':
        prepareHeaders = fn;
        break;
      case 'prepareMethod':
        prepareMethod = fn;
        break;
      case 'prepareParams':
        prepareParams = fn;
        break;
      case 'preparePath':
        preparePath = fn;
        break;
      case 'graphqlBody':
        graphqlBody = fn;
        break;
      case 'graphqlErrors':
        graphqlErrors = fn;
        break;
      case 'prepareQuery':
        prepareQuery = fn;
        break;
      case 'resultBasic':
        resultBasic = fn;
        break;
      case 'resultBody':
        resultBody = fn;
        break;
      case 'resultHeaders':
        resultHeaders = fn;
        break;
      case 'transformRequest':
        transformRequest = fn;
        break;
      case 'transformResponse':
        transformResponse = fn;
        break;
      default:
        custom[name] = fn;
    }
  }

  // String-keyed lookup (corpus test runner, custom utilities).
  dynamic byName(String name) {
    switch (name) {
      case 'clean':
        return clean;
      case 'done':
        return done;
      case 'makeError':
        return makeError;
      case 'featureAdd':
        return featureAdd;
      case 'featureHook':
        return featureHook;
      case 'featureInit':
        return featureInit;
      case 'fetcher':
        return fetcher;
      case 'makeFetchDef':
        return makeFetchDef;
      case 'makeContext':
        return makeContext;
      case 'makeOptions':
        return makeOptions;
      case 'makeRequest':
        return makeRequest;
      case 'makeResponse':
        return makeResponse;
      case 'makeResult':
        return makeResult;
      case 'makePoint':
        return makePoint;
      case 'makeSpec':
        return makeSpec;
      case 'makeUrl':
        return makeUrl;
      case 'param':
        return param;
      case 'prepareAuth':
        return prepareAuth;
      case 'prepareBody':
        return prepareBody;
      case 'prepareHeaders':
        return prepareHeaders;
      case 'prepareMethod':
        return prepareMethod;
      case 'prepareParams':
        return prepareParams;
      case 'preparePath':
        return preparePath;
      case 'prepareQuery':
        return prepareQuery;
      case 'resultBasic':
        return resultBasic;
      case 'resultBody':
        return resultBody;
      case 'resultHeaders':
        return resultHeaders;
      case 'transformRequest':
        return transformRequest;
      case 'transformResponse':
        return transformResponse;
      default:
        return custom[name];
    }
  }
}
