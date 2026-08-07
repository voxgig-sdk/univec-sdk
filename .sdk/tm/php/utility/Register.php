<?php
declare(strict_types=1);

// Univec SDK utility registration

require_once __DIR__ . '/../core/UtilityType.php';
require_once __DIR__ . '/Clean.php';
require_once __DIR__ . '/Done.php';
require_once __DIR__ . '/MakeError.php';
require_once __DIR__ . '/FeatureAdd.php';
require_once __DIR__ . '/FeatureHook.php';
require_once __DIR__ . '/FeatureInit.php';
require_once __DIR__ . '/Fetcher.php';
require_once __DIR__ . '/MakeFetchDef.php';
require_once __DIR__ . '/MakeContext.php';
require_once __DIR__ . '/MakeOptions.php';
require_once __DIR__ . '/MakeRequest.php';
require_once __DIR__ . '/MakeResponse.php';
require_once __DIR__ . '/MakeResult.php';
require_once __DIR__ . '/MakePoint.php';
require_once __DIR__ . '/MakeSpec.php';
require_once __DIR__ . '/MakeUrl.php';
require_once __DIR__ . '/Param.php';
require_once __DIR__ . '/PrepareAuth.php';
require_once __DIR__ . '/PrepareBody.php';
require_once __DIR__ . '/PrepareHeaders.php';
require_once __DIR__ . '/PrepareMethod.php';
require_once __DIR__ . '/PrepareParams.php';
require_once __DIR__ . '/PreparePath.php';
require_once __DIR__ . '/PrepareQuery.php';
require_once __DIR__ . '/ResultBasic.php';
require_once __DIR__ . '/ResultBody.php';
require_once __DIR__ . '/ResultHeaders.php';
require_once __DIR__ . '/TransformRequest.php';
require_once __DIR__ . '/TransformResponse.php';

UnivecUtility::setRegistrar(function (UnivecUtility $u): void {
    $u->clean = [UnivecClean::class, 'call'];
    $u->done = [UnivecDone::class, 'call'];
    $u->make_error = [UnivecMakeError::class, 'call'];
    $u->feature_add = [UnivecFeatureAdd::class, 'call'];
    $u->feature_hook = [UnivecFeatureHook::class, 'call'];
    $u->feature_init = [UnivecFeatureInit::class, 'call'];
    $u->fetcher = [UnivecFetcher::class, 'call'];
    $u->make_fetch_def = [UnivecMakeFetchDef::class, 'call'];
    $u->make_context = [UnivecMakeContext::class, 'call'];
    $u->make_options = [UnivecMakeOptions::class, 'call'];
    $u->make_request = [UnivecMakeRequest::class, 'call'];
    $u->make_response = [UnivecMakeResponse::class, 'call'];
    $u->make_result = [UnivecMakeResult::class, 'call'];
    $u->make_point = [UnivecMakePoint::class, 'call'];
    $u->make_spec = [UnivecMakeSpec::class, 'call'];
    $u->make_url = [UnivecMakeUrl::class, 'call'];
    $u->param = [UnivecParam::class, 'call'];
    $u->prepare_auth = [UnivecPrepareAuth::class, 'call'];
    $u->prepare_body = [UnivecPrepareBody::class, 'call'];
    $u->prepare_headers = [UnivecPrepareHeaders::class, 'call'];
    $u->prepare_method = [UnivecPrepareMethod::class, 'call'];
    $u->prepare_params = [UnivecPrepareParams::class, 'call'];
    $u->prepare_path = [UnivecPreparePath::class, 'call'];
    $u->prepare_query = [UnivecPrepareQuery::class, 'call'];
    $u->result_basic = [UnivecResultBasic::class, 'call'];
    $u->result_body = [UnivecResultBody::class, 'call'];
    $u->result_headers = [UnivecResultHeaders::class, 'call'];
    $u->transform_request = [UnivecTransformRequest::class, 'call'];
    $u->transform_response = [UnivecTransformResponse::class, 'call'];
});
