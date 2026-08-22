// Typed models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types are mapped
// from the canonical type sentinels. Do not edit by hand.
//
// These are DOCUMENTARY: the SDK runtime is dynamic (ops take/return the
// `Value` enum), so nothing consumes these structs yet — they mirror the
// entity/op shapes for reference and IDE support.
#![allow(dead_code, non_snake_case, unused_imports)]

use crate::utility::voxgigstruct::Value;

/// Convert is the typed data model for the convert entity.
#[derive(Debug, Clone)]
pub struct Convert {
    pub bridge_model: String,
    pub embeddings: Vec<Value>,
    pub source_model: String,
    pub target_model: String,
    pub texts: Vec<Value>,
}

/// ConvertCreateData is the typed request payload for Convert.create.
#[derive(Debug, Clone)]
pub struct ConvertCreateData {
    pub bridge_model: String,
    pub embeddings: Vec<Value>,
    pub source_model: String,
    pub target_model: String,
    pub texts: Vec<Value>,
}

/// Embed is the typed data model for the embed entity.
#[derive(Debug, Clone)]
pub struct Embed {
    pub embeddings: Vec<Value>,
    pub model: String,
    pub texts: Vec<Value>,
}

/// EmbedCreateData is the typed request payload for Embed.create.
#[derive(Debug, Clone)]
pub struct EmbedCreateData {
    pub embeddings: Vec<Value>,
    pub model: String,
    pub texts: Vec<Value>,
}

/// EphemeralKey is the typed data model for the ephemeral_key entity.
#[derive(Debug, Clone)]
pub struct EphemeralKey {
    pub dailylimit: i64,
    pub dailyused: i64,
    pub key: String,
    pub resetsat: String,
}

/// EphemeralKeyCreateData is the typed request payload for EphemeralKey.create.
#[derive(Debug, Clone)]
pub struct EphemeralKeyCreateData {
    pub dailylimit: i64,
    pub dailyused: i64,
    pub key: String,
    pub resetsat: String,
}

/// Model is the typed data model for the model entity.
#[derive(Debug, Clone)]
pub struct Model {
    pub eval: Option<std::collections::HashMap<String, Value>>,
    pub executionprovider: Option<String>,
    pub modelcard: Option<std::collections::HashMap<String, Value>>,
    pub modeltype: String,
    pub name: String,
    pub sequencelen: Option<i64>,
    pub sourcedim: Option<i64>,
    pub sourcemodel: Option<String>,
    pub targetdim: i64,
    pub targetmodel: String,
}

/// ModelListMatch is the typed request payload for Model.list.
#[derive(Debug, Clone)]
pub struct ModelListMatch {
    pub eval: Option<std::collections::HashMap<String, Value>>,
    pub executionprovider: Option<String>,
    pub modelcard: Option<std::collections::HashMap<String, Value>>,
    pub modeltype: Option<String>,
    pub name: Option<String>,
    pub sequencelen: Option<i64>,
    pub sourcedim: Option<i64>,
    pub sourcemodel: Option<String>,
    pub targetdim: Option<i64>,
    pub targetmodel: Option<String>,
}

