# frozen_string_literal: true

# Typed models for the Univec SDK.
#
# GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
# params (op.<name>.points[].args.params[]). Member types come from the
# canonical type sentinels via @voxgig/sdkgen canonToType (source of truth:
# @voxgig/apidef VALID_CANON). Ruby types are unenforced; these YARD
# annotations document the shapes. Do not edit by hand.

# Convert entity data model.
#
# @!attribute [rw] embeddings
#   @return [Array]
#
# @!attribute [rw] source_model
#   @return [String]
#
# @!attribute [rw] target_model
#   @return [String]
Convert = Struct.new(
  :embeddings,
  :source_model,
  :target_model,
  keyword_init: true
)

# Request payload for Convert#create.
#
# @!attribute [rw] embeddings
#   @return [Array]
#
# @!attribute [rw] source_model
#   @return [String]
#
# @!attribute [rw] target_model
#   @return [String]
ConvertCreateData = Struct.new(
  :embeddings,
  :source_model,
  :target_model,
  keyword_init: true
)

# Embed entity data model.
#
# @!attribute [rw] embeddings
#   @return [Array]
#
# @!attribute [rw] model
#   @return [String]
#
# @!attribute [rw] texts
#   @return [Array]
Embed = Struct.new(
  :embeddings,
  :model,
  :texts,
  keyword_init: true
)

# Request payload for Embed#create.
#
# @!attribute [rw] embeddings
#   @return [Array]
#
# @!attribute [rw] model
#   @return [String]
#
# @!attribute [rw] texts
#   @return [Array]
EmbedCreateData = Struct.new(
  :embeddings,
  :model,
  :texts,
  keyword_init: true
)

# EphemeralKey entity data model.
#
# @!attribute [rw] dailyLimit
#   @return [Integer]
#
# @!attribute [rw] dailyUsed
#   @return [Integer]
#
# @!attribute [rw] key
#   @return [String]
#
# @!attribute [rw] resetsAt
#   @return [String]
EphemeralKey = Struct.new(
  :dailyLimit,
  :dailyUsed,
  :key,
  :resetsAt,
  keyword_init: true
)

# Request payload for EphemeralKey#create.
#
# @!attribute [rw] dailyLimit
#   @return [Integer]
#
# @!attribute [rw] dailyUsed
#   @return [Integer]
#
# @!attribute [rw] key
#   @return [String]
#
# @!attribute [rw] resetsAt
#   @return [String]
EphemeralKeyCreateData = Struct.new(
  :dailyLimit,
  :dailyUsed,
  :key,
  :resetsAt,
  keyword_init: true
)

# Model entity data model.
#
# @!attribute [rw] eval
#   @return [Hash, nil]
#
# @!attribute [rw] executionProvider
#   @return [String, nil]
#
# @!attribute [rw] modelCard
#   @return [Hash, nil]
#
# @!attribute [rw] modelType
#   @return [String]
#
# @!attribute [rw] name
#   @return [String]
#
# @!attribute [rw] sequenceLen
#   @return [Integer, nil]
#
# @!attribute [rw] sourceDim
#   @return [Integer, nil]
#
# @!attribute [rw] sourceModel
#   @return [String, nil]
#
# @!attribute [rw] targetDim
#   @return [Integer]
#
# @!attribute [rw] targetModel
#   @return [String]
Model = Struct.new(
  :eval,
  :executionProvider,
  :modelCard,
  :modelType,
  :name,
  :sequenceLen,
  :sourceDim,
  :sourceModel,
  :targetDim,
  :targetModel,
  keyword_init: true
)

# Request payload for Model#list.
#
# @!attribute [rw] eval
#   @return [Hash, nil]
#
# @!attribute [rw] executionProvider
#   @return [String, nil]
#
# @!attribute [rw] modelCard
#   @return [Hash, nil]
#
# @!attribute [rw] modelType
#   @return [String, nil]
#
# @!attribute [rw] name
#   @return [String, nil]
#
# @!attribute [rw] sequenceLen
#   @return [Integer, nil]
#
# @!attribute [rw] sourceDim
#   @return [Integer, nil]
#
# @!attribute [rw] sourceModel
#   @return [String, nil]
#
# @!attribute [rw] targetDim
#   @return [Integer, nil]
#
# @!attribute [rw] targetModel
#   @return [String, nil]
ModelListMatch = Struct.new(
  :eval,
  :executionProvider,
  :modelCard,
  :modelType,
  :name,
  :sequenceLen,
  :sourceDim,
  :sourceModel,
  :targetDim,
  :targetModel,
  keyword_init: true
)

