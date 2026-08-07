// Typed models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels via @voxgig/sdkgen canonToType (source of truth:
// @voxgig/apidef VALID_CANON). Do not edit by hand.
package entity

import "encoding/json"

// Convert is the typed data model for the convert entity.
type Convert struct {
	BridgeModel string `json:"bridge_model"`
	Data map[string]any `json:"data"`
	Embedding []any `json:"embedding"`
	SourceModel string `json:"source_model"`
	Success bool `json:"success"`
	TargetModel string `json:"target_model"`
	Text []any `json:"text"`
}

// ConvertCreateData is the typed request payload for Convert.CreateTyped.
type ConvertCreateData struct {
	BridgeModel string `json:"bridge_model"`
	Data map[string]any `json:"data"`
	Embedding []any `json:"embedding"`
	SourceModel string `json:"source_model"`
	Success bool `json:"success"`
	TargetModel string `json:"target_model"`
	Text []any `json:"text"`
}

// Embed is the typed data model for the embed entity.
type Embed struct {
	Data map[string]any `json:"data"`
	Model string `json:"model"`
	Success bool `json:"success"`
	Text []any `json:"text"`
}

// EmbedCreateData is the typed request payload for Embed.CreateTyped.
type EmbedCreateData struct {
	Data map[string]any `json:"data"`
	Model string `json:"model"`
	Success bool `json:"success"`
	Text []any `json:"text"`
}

// EphemeralKey is the typed data model for the ephemeral_key entity.
type EphemeralKey struct {
	Data map[string]any `json:"data"`
	Success bool `json:"success"`
}

// EphemeralKeyCreateData is the typed request payload for EphemeralKey.CreateTyped.
type EphemeralKeyCreateData struct {
	Data map[string]any `json:"data"`
	Success bool `json:"success"`
}

// Model is the typed data model for the model entity.
type Model struct {
	Eval *map[string]any `json:"eval,omitempty"`
	ExecutionProvider *string `json:"execution_provider,omitempty"`
	ModelCard *map[string]any `json:"model_card,omitempty"`
	ModelType string `json:"model_type"`
	Name string `json:"name"`
	SequenceLen *int `json:"sequence_len,omitempty"`
	SourceDim *int `json:"source_dim,omitempty"`
	SourceModel *string `json:"source_model,omitempty"`
	TargetDim int `json:"target_dim"`
	TargetModel string `json:"target_model"`
}

// ModelListMatch is the typed request payload for Model.ListTyped.
type ModelListMatch struct {
	Eval *map[string]any `json:"eval,omitempty"`
	ExecutionProvider *string `json:"execution_provider,omitempty"`
	ModelCard *map[string]any `json:"model_card,omitempty"`
	ModelType *string `json:"model_type,omitempty"`
	Name *string `json:"name,omitempty"`
	SequenceLen *int `json:"sequence_len,omitempty"`
	SourceDim *int `json:"source_dim,omitempty"`
	SourceModel *string `json:"source_model,omitempty"`
	TargetDim *int `json:"target_dim,omitempty"`
	TargetModel *string `json:"target_model,omitempty"`
}

// asMap turns a typed request/data struct into the map[string]any the
// runtime op pipeline consumes, honouring the json tags above.
func asMap(v any) map[string]any {
	out := map[string]any{}
	b, err := json.Marshal(v)
	if err != nil {
		return out
	}
	_ = json.Unmarshal(b, &out)
	return out
}

// typedFrom decodes a runtime value (a map[string]any produced by the op
// pipeline) into a typed model T via a JSON round-trip. On any error it
// returns the zero value of T; the op's own (value, error) tuple carries the
// real error.
func typedFrom[T any](v any) T {
	var out T
	if v == nil {
		return out
	}
	b, err := json.Marshal(v)
	if err != nil {
		return out
	}
	_ = json.Unmarshal(b, &out)
	return out
}

// typedSliceFrom decodes a runtime list value ([]any of maps) into a typed
// slice []T via a JSON round-trip, for list ops.
func typedSliceFrom[T any](v any) []T {
	var out []T
	if v == nil {
		return out
	}
	b, err := json.Marshal(v)
	if err != nil {
		return out
	}
	_ = json.Unmarshal(b, &out)
	return out
}
