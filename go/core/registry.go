package core

var UtilityRegistrar func(u *Utility)

var NewBaseFeatureFunc func() Feature

var NewAuditFeatureFunc func() Feature

var NewCacheFeatureFunc func() Feature

var NewClienttrackFeatureFunc func() Feature

var NewCostFeatureFunc func() Feature

var NewDebugFeatureFunc func() Feature

var NewIdempotencyFeatureFunc func() Feature

var NewLogFeatureFunc func() Feature

var NewMetricsFeatureFunc func() Feature

var NewNetsimFeatureFunc func() Feature

var NewPagingFeatureFunc func() Feature

var NewProxyFeatureFunc func() Feature

var NewRatelimitFeatureFunc func() Feature

var NewRbacFeatureFunc func() Feature

var NewRetryFeatureFunc func() Feature

var NewStreamingFeatureFunc func() Feature

var NewTelemetryFeatureFunc func() Feature

var NewTestFeatureFunc func() Feature

var NewTimeoutFeatureFunc func() Feature

var NewConvertEntityFunc func(client *UnivecSDK, entopts map[string]any) UnivecEntity

var NewEmbedEntityFunc func(client *UnivecSDK, entopts map[string]any) UnivecEntity

var NewEphemeralKeyEntityFunc func(client *UnivecSDK, entopts map[string]any) UnivecEntity

var NewModelEntityFunc func(client *UnivecSDK, entopts map[string]any) UnivecEntity

