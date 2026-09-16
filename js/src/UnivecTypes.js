// Typed models for the Univec SDK (JSDoc typedefs).
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels via @voxgig/sdkgen canonToType (source of truth:
// @voxgig/apidef VALID_CANON). Annotations only — no runtime effect. Do not
// edit by hand.

/**
 * @typedef {Object} Convert
 * @property {Array} embeddings
 * @property {string} source_model
 * @property {string} target_model
 */

/**
 * @typedef {Object} ConvertCreateData
 * @property {Array} embeddings
 * @property {string} source_model
 * @property {string} target_model
 */

/**
 * @typedef {Object} Embed
 * @property {Array} embeddings
 * @property {string} model
 * @property {Array} texts
 */

/**
 * @typedef {Object} EmbedCreateData
 * @property {Array} embeddings
 * @property {string} model
 * @property {Array} texts
 */

/**
 * @typedef {Object} EphemeralKey
 * @property {number} dailyLimit
 * @property {number} dailyUsed
 * @property {string} key
 * @property {string} resetsAt
 */

/**
 * @typedef {Object} EphemeralKeyCreateData
 * @property {number} dailyLimit
 * @property {number} dailyUsed
 * @property {string} key
 * @property {string} resetsAt
 */

/**
 * @typedef {Object} Model
 * @property {Object} [eval]
 * @property {string} [executionProvider]
 * @property {Object} [modelCard]
 * @property {string} modelType
 * @property {string} name
 * @property {number} [sequenceLen]
 * @property {number} [sourceDim]
 * @property {string} [sourceModel]
 * @property {number} targetDim
 * @property {string} targetModel
 */

/**
 * @typedef {Object} ModelListMatch
 * @property {Object} [eval]
 * @property {string} [executionProvider]
 * @property {Object} [modelCard]
 * @property {string} [modelType]
 * @property {string} [name]
 * @property {number} [sequenceLen]
 * @property {number} [sourceDim]
 * @property {string} [sourceModel]
 * @property {number} [targetDim]
 * @property {string} [targetModel]
 */

