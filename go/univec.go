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
	core.NewTestFeatureFunc = func() core.Feature {
		return feature.NewTestFeature()
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
var NewTestFeature = feature.NewTestFeature
