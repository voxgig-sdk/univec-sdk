package voxgigunivecsdk

import (
	"github.com/voxgig-sdk/univec-sdk/go/core"
	"github.com/voxgig-sdk/univec-sdk/go/entity"
	"github.com/voxgig-sdk/univec-sdk/go/feature"
	_ "github.com/voxgig-sdk/univec-sdk/go/utility"
)

// Type aliases preserve external API.
type UnivecSDK = core.UnivecSDK
type Context = core.Context
type Utility = core.Utility
type Feature = core.Feature
type Entity = core.Entity
type UnivecEntity = core.UnivecEntity
type FetcherFunc = core.FetcherFunc
type Spec = core.Spec
type Result = core.Result
type Response = core.Response
type Operation = core.Operation
type Control = core.Control
type UnivecError = core.UnivecError

// BaseFeature from feature package.
type BaseFeature = feature.BaseFeature

func init() {
	core.NewBaseFeatureFunc = func() core.Feature {
		return feature.NewBaseFeature()
	}
	core.NewAuditFeatureFunc = func() core.Feature {
		return feature.NewAuditFeature()
	}
	core.NewCacheFeatureFunc = func() core.Feature {
		return feature.NewCacheFeature()
	}
	core.NewClienttrackFeatureFunc = func() core.Feature {
		return feature.NewClienttrackFeature()
	}
	core.NewCostFeatureFunc = func() core.Feature {
		return feature.NewCostFeature()
	}
	core.NewDebugFeatureFunc = func() core.Feature {
		return feature.NewDebugFeature()
	}
	core.NewIdempotencyFeatureFunc = func() core.Feature {
		return feature.NewIdempotencyFeature()
	}
	core.NewLogFeatureFunc = func() core.Feature {
		return feature.NewLogFeature()
	}
	core.NewMetricsFeatureFunc = func() core.Feature {
		return feature.NewMetricsFeature()
	}
	core.NewNetsimFeatureFunc = func() core.Feature {
		return feature.NewNetsimFeature()
	}
	core.NewPagingFeatureFunc = func() core.Feature {
		return feature.NewPagingFeature()
	}
	core.NewProxyFeatureFunc = func() core.Feature {
		return feature.NewProxyFeature()
	}
	core.NewRatelimitFeatureFunc = func() core.Feature {
		return feature.NewRatelimitFeature()
	}
	core.NewRbacFeatureFunc = func() core.Feature {
		return feature.NewRbacFeature()
	}
	core.NewRetryFeatureFunc = func() core.Feature {
		return feature.NewRetryFeature()
	}
	core.NewSecretsFeatureFunc = func() core.Feature {
		return feature.NewSecretsFeature()
	}
	core.NewStreamingFeatureFunc = func() core.Feature {
		return feature.NewStreamingFeature()
	}
	core.NewTelemetryFeatureFunc = func() core.Feature {
		return feature.NewTelemetryFeature()
	}
	core.NewTestFeatureFunc = func() core.Feature {
		return feature.NewTestFeature()
	}
	core.NewTimeoutFeatureFunc = func() core.Feature {
		return feature.NewTimeoutFeature()
	}
	core.NewConvertEntityFunc = func(client *core.UnivecSDK, entopts map[string]any) core.UnivecEntity {
		return entity.NewConvertEntity(client, entopts)
	}
	core.NewEmbedEntityFunc = func(client *core.UnivecSDK, entopts map[string]any) core.UnivecEntity {
		return entity.NewEmbedEntity(client, entopts)
	}
	core.NewEphemeralKeyEntityFunc = func(client *core.UnivecSDK, entopts map[string]any) core.UnivecEntity {
		return entity.NewEphemeralKeyEntity(client, entopts)
	}
	core.NewModelEntityFunc = func(client *core.UnivecSDK, entopts map[string]any) core.UnivecEntity {
		return entity.NewModelEntity(client, entopts)
	}
}

// Constructor re-exports.
var NewUnivecSDK = core.NewUnivecSDK
var TestSDK = core.TestSDK
var NewContext = core.NewContext
var NewSpec = core.NewSpec
var NewResult = core.NewResult
var NewResponse = core.NewResponse
var NewOperation = core.NewOperation
var MakeConfig = core.MakeConfig
var SharedConfig = core.SharedConfig

// No-arg convenience constructors. Go has no default-argument syntax,
// so these aliases let callers write `sdk.New()` / `sdk.Test()`
// instead of `sdk.NewUnivecSDK(nil)` / `sdk.TestSDK(nil, nil)`
// for the common no-options case.
func New() *UnivecSDK  { return NewUnivecSDK(nil) }
func Test() *UnivecSDK { return TestSDK(nil, nil) }
var NewBaseFeature = feature.NewBaseFeature
var NewAuditFeature = feature.NewAuditFeature
var NewCacheFeature = feature.NewCacheFeature
var NewClienttrackFeature = feature.NewClienttrackFeature
var NewCostFeature = feature.NewCostFeature
var NewDebugFeature = feature.NewDebugFeature
var NewIdempotencyFeature = feature.NewIdempotencyFeature
var NewLogFeature = feature.NewLogFeature
var NewMetricsFeature = feature.NewMetricsFeature
var NewNetsimFeature = feature.NewNetsimFeature
var NewPagingFeature = feature.NewPagingFeature
var NewProxyFeature = feature.NewProxyFeature
var NewRatelimitFeature = feature.NewRatelimitFeature
var NewRbacFeature = feature.NewRbacFeature
var NewRetryFeature = feature.NewRetryFeature
var NewSecretsFeature = feature.NewSecretsFeature
var NewStreamingFeature = feature.NewStreamingFeature
var NewTelemetryFeature = feature.NewTelemetryFeature
var NewTestFeature = feature.NewTestFeature
var NewTimeoutFeature = feature.NewTimeoutFeature
