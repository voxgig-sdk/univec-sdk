// Typed models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types are mapped
// from the canonical type sentinels. Do not edit by hand.
//
// These are DOCUMENTARY: the SDK runtime is dynamic (ops take/return the
// `Value` enum), so nothing consumes these structs yet — they mirror the
// entity/op shapes for reference and IDE support.

import Foundation

/// Convert is the typed data model for the convert entity.
public struct Convert {
  public var embeddings: [Value]
  public var sourceModel: String
  public var targetModel: String
}

/// ConvertCreateData is the typed request payload for Convert.create.
public struct ConvertCreateData {
  public var embeddings: [Value]
  public var sourceModel: String
  public var targetModel: String
}

/// Embed is the typed data model for the embed entity.
public struct Embed {
  public var embeddings: [Value]
  public var model: String
  public var texts: [Value]
}

/// EmbedCreateData is the typed request payload for Embed.create.
public struct EmbedCreateData {
  public var embeddings: [Value]
  public var model: String
  public var texts: [Value]
}

/// EphemeralKey is the typed data model for the ephemeral_key entity.
public struct EphemeralKey {
  public var dailyLimit: Int
  public var dailyUsed: Int
  public var key: String
  public var resetsAt: String
}

/// EphemeralKeyCreateData is the typed request payload for EphemeralKey.create.
public struct EphemeralKeyCreateData {
  public var dailyLimit: Int
  public var dailyUsed: Int
  public var key: String
  public var resetsAt: String
}

/// Model is the typed data model for the model entity.
public struct Model {
  public var eval: VMap?
  public var executionProvider: String?
  public var modelCard: VMap?
  public var modelType: String
  public var name: String
  public var sequenceLen: Int?
  public var sourceDim: Int?
  public var sourceModel: String?
  public var targetDim: Int
  public var targetModel: String
}

/// ModelListMatch is the typed request payload for Model.list.
public struct ModelListMatch {
  public var eval: VMap?
  public var executionProvider: String?
  public var modelCard: VMap?
  public var modelType: String?
  public var name: String?
  public var sequenceLen: Int?
  public var sourceDim: Int?
  public var sourceModel: String?
  public var targetDim: Int?
  public var targetModel: String?
}

