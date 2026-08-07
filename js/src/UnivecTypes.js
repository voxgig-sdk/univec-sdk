// Typed models for the Univec SDK (JSDoc typedefs).
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels via @voxgig/sdkgen canonToType (source of truth:
// @voxgig/apidef VALID_CANON). Annotations only — no runtime effect. Do not
// edit by hand.

/**
 * @typedef {Object} Convert
 * @property {string} bridge_model
 * @property {Object} data
 * @property {Array} embedding
 * @property {string} source_model
 * @property {boolean} success
 * @property {string} target_model
 * @property {Array} text
 */

/**
 * @typedef {Object} ConvertCreateData
 * @property {string} bridge_model
 * @property {Object} data
 * @property {Array} embedding
 * @property {string} source_model
 * @property {boolean} success
 * @property {string} target_model
 * @property {Array} text
 */

/**
 * @typedef {Object} Embed
 * @property {Object} data
 * @property {string} model
 * @property {boolean} success
 * @property {Array} text
 */

/**
 * @typedef {Object} EmbedCreateData
 * @property {Object} data
 * @property {string} model
 * @property {boolean} success
 * @property {Array} text
 */

/**
 * @typedef {Object} EphemeralKey
 * @property {Object} data
 * @property {boolean} success
 */

/**
 * @typedef {Object} EphemeralKeyCreateData
 * @property {Object} data
 * @property {boolean} success
 */

/**
 * @typedef {Object} Model
 * @property {Object} [eval]
 * @property {string} [execution_provider]
 * @property {Object} [model_card]
 * @property {string} model_type
 * @property {string} name
 * @property {number} [sequence_len]
 * @property {number} [source_dim]
 * @property {string} [source_model]
 * @property {number} target_dim
 * @property {string} target_model
 */

/**
 * @typedef {Object} ModelListMatch
 * @property {Object} [eval]
 * @property {string} [execution_provider]
 * @property {Object} [model_card]
 * @property {string} [model_type]
 * @property {string} [name]
 * @property {number} [sequence_len]
 * @property {number} [source_dim]
 * @property {string} [source_model]
 * @property {number} [target_dim]
 * @property {string} [target_model]
 */

