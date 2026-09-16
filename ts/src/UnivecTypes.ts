// Typed models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels via @voxgig/sdkgen canonToType (source of truth:
// @voxgig/apidef VALID_CANON). Do not edit by hand.

export interface Convert {
  embeddings: any[]
  source_model: string
  target_model: string
}

export interface ConvertCreateData {
  embeddings: any[]
  source_model: string
  target_model: string

  // Selects a custom action instead of the plain create:
  //   'bridge' | 'ephemeral' | 'ephemeral_bridge'
  // The remaining keys are that action's own payload.
  $action?: string
  [action: string]: any
}

export interface Embed {
  embeddings: any[]
  model: string
  texts: any[]
}

export interface EmbedCreateData {
  embeddings: any[]
  model: string
  texts: any[]

  // Selects a custom action instead of the plain create:
  //   'ephemeral'
  // The remaining keys are that action's own payload.
  $action?: string
  [action: string]: any
}

export interface EphemeralKey {
  dailyLimit: number
  dailyUsed: number
  key: string
  resetsAt: string
}

export interface EphemeralKeyCreateData {
  dailyLimit: number
  dailyUsed: number
  key: string
  resetsAt: string
}

export interface Model {
  eval?: Record<string, any>
  executionProvider?: string
  modelCard?: Record<string, any>
  modelType: string
  name: string
  sequenceLen?: number
  sourceDim?: number
  sourceModel?: string
  targetDim: number
  targetModel: string
}

export interface ModelListMatch {
  eval?: Record<string, any>
  executionProvider?: string
  modelCard?: Record<string, any>
  modelType?: string
  name?: string
  sequenceLen?: number
  sourceDim?: number
  sourceModel?: string
  targetDim?: number
  targetModel?: string
}

