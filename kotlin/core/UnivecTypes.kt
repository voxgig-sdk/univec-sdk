package voxgig.univecsdk.core

// Typed reference models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels (source of truth: @voxgig/apidef VALID_CANON). Do
// not edit by hand.
//
// These types are documentation/DX reference shapes ONLY. The SDK ops take and
// return the loose object model (MutableMap<String, Any?> / Any?) at runtime,
// so these types are not wired into the op signatures — use them to describe a
// payload before converting it to a map. Every component is a nullable type, so
// an optional (req:false) key needs no distinct rendering.

@Suppress("unused")
object UnivecTypes {

  data class Convert(val bridge_model: String?, val embeddings: List<Any?>?, val source_model: String?, val target_model: String?, val texts: List<Any?>?)

  data class ConvertCreateData(val bridge_model: String?, val embeddings: List<Any?>?, val source_model: String?, val target_model: String?, val texts: List<Any?>?)

  data class Embed(val embeddings: List<Any?>?, val model: String?, val texts: List<Any?>?)

  data class EmbedCreateData(val embeddings: List<Any?>?, val model: String?, val texts: List<Any?>?)

  data class EphemeralKey(val dailyLimit: Long?, val dailyUsed: Long?, val key: String?, val resetsAt: String?)

  data class EphemeralKeyCreateData(val dailyLimit: Long?, val dailyUsed: Long?, val key: String?, val resetsAt: String?)

  data class Model(val eval: Map<String, Any?>?, val executionProvider: String?, val modelCard: Map<String, Any?>?, val modelType: String?, val name: String?, val sequenceLen: Long?, val sourceDim: Long?, val sourceModel: String?, val targetDim: Long?, val targetModel: String?)

  data class ModelListMatch(val eval: Map<String, Any?>?, val executionProvider: String?, val modelCard: Map<String, Any?>?, val modelType: String?, val name: String?, val sequenceLen: Long?, val sourceDim: Long?, val sourceModel: String?, val targetDim: Long?, val targetModel: String?)

}
