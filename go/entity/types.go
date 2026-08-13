// Typed models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels via @voxgig/sdkgen canonToType (source of truth:
// @voxgig/apidef VALID_CANON). Do not edit by hand.
package entity

import (
	"encoding/json"

	"github.com/voxgig-sdk/univec-sdk/go/core"
)

// Convert is the typed data model for the convert entity.
type Convert struct {
	BridgeModel string `json:"bridge_model"`
	Embeddings []any `json:"embeddings"`
	SourceModel string `json:"source_model"`
	TargetModel string `json:"target_model"`
	Texts []any `json:"texts"`
}

// ConvertCreateData is the typed request payload for Convert.CreateTyped.
type ConvertCreateData struct {
	BridgeModel string `json:"bridge_model"`
	Embeddings []any `json:"embeddings"`
	SourceModel string `json:"source_model"`
	TargetModel string `json:"target_model"`
	Texts []any `json:"texts"`
}

// Embed is the typed data model for the embed entity.
type Embed struct {
	Embeddings []any `json:"embeddings"`
	Model string `json:"model"`
	Texts []any `json:"texts"`
}

// EmbedCreateData is the typed request payload for Embed.CreateTyped.
type EmbedCreateData struct {
	Embeddings []any `json:"embeddings"`
	Model string `json:"model"`
	Texts []any `json:"texts"`
}

// EphemeralKey is the typed data model for the ephemeral_key entity.
type EphemeralKey struct {
	DailyLimit int `json:"dailyLimit"`
	DailyUsed int `json:"dailyUsed"`
	Key string `json:"key"`
	ResetsAt string `json:"resetsAt"`
}

// EphemeralKeyCreateData is the typed request payload for EphemeralKey.CreateTyped.
type EphemeralKeyCreateData struct {
	DailyLimit int `json:"dailyLimit"`
	DailyUsed int `json:"dailyUsed"`
	Key string `json:"key"`
	ResetsAt string `json:"resetsAt"`
}

// Model is the typed data model for the model entity.
type Model struct {
	Eval *map[string]any `json:"eval,omitempty"`
	ExecutionProvider *string `json:"executionProvider,omitempty"`
	ModelCard *map[string]any `json:"modelCard,omitempty"`
	ModelType string `json:"modelType"`
	Name string `json:"name"`
	SequenceLen *int `json:"sequenceLen,omitempty"`
	SourceDim *int `json:"sourceDim,omitempty"`
	SourceModel *string `json:"sourceModel,omitempty"`
	TargetDim int `json:"targetDim"`
	TargetModel string `json:"targetModel"`
}

// ModelListMatch is the typed request payload for Model.ListTyped.
type ModelListMatch struct {
	Eval *map[string]any `json:"eval,omitempty"`
	ExecutionProvider *string `json:"executionProvider,omitempty"`
	ModelCard *map[string]any `json:"modelCard,omitempty"`
	ModelType *string `json:"modelType,omitempty"`
	Name *string `json:"name,omitempty"`
	SequenceLen *int `json:"sequenceLen,omitempty"`
	SourceDim *int `json:"sourceDim,omitempty"`
	SourceModel *string `json:"sourceModel,omitempty"`
	TargetDim *int `json:"targetDim,omitempty"`
	TargetModel *string `json:"targetModel,omitempty"`
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

// entityData unwraps an entity to its data map.
//
// Operations resolve to the ENTITY, not the raw data (see AGENTS.md), and an
// entity's fields are UNEXPORTED — marshalling one directly yields `{}`, so
// every typed accessor would silently hand back a zero-valued struct. The
// typed boundary therefore takes the data hop first.
func entityData(v any) any {
	if ent, ok := v.(core.Entity); ok {
		return ent.Data()
	}
	return v
}

// typedFrom decodes a runtime value (an entity, or the map[string]any the op
// pipeline produced) into a typed model T via a JSON round-trip. On any error
// it returns the zero value of T; the op's own (value, error) tuple carries
// the real error.
func typedFrom[T any](v any) T {
	var out T
	v = entityData(v)
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

// typedSliceFrom decodes a runtime list value into a typed slice []T via a
// JSON round-trip, for list ops. `list` resolves to a slice of ENTITY
// instances, so each element takes the data hop.
func typedSliceFrom[T any](v any) []T {
	var out []T
	if v == nil {
		return out
	}
	if list, ok := v.([]any); ok {
		unwrapped := make([]any, 0, len(list))
		for _, item := range list {
			unwrapped = append(unwrapped, entityData(item))
		}
		v = unwrapped
	}
	b, err := json.Marshal(v)
	if err != nil {
		return out
	}
	_ = json.Unmarshal(b, &out)
	return out
}
