package core

var UtilityRegistrar func(u *Utility)

var NewBaseFeatureFunc func() Feature

var NewTestFeatureFunc func() Feature

var NewConvertEntityFunc func(client *UnivecSDK, entopts map[string]any) UnivecEntity

var NewEmbedEntityFunc func(client *UnivecSDK, entopts map[string]any) UnivecEntity

var NewEphemeralKeyEntityFunc func(client *UnivecSDK, entopts map[string]any) UnivecEntity

var NewModelEntityFunc func(client *UnivecSDK, entopts map[string]any) UnivecEntity

