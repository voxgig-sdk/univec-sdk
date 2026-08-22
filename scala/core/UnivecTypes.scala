package voxgig.univecsdk.core

// Typed reference models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels (source of truth: @voxgig/apidef VALID_CANON). Do
// not edit by hand.
//
// These case classes are documentation/DX reference shapes ONLY. The SDK ops
// take and return the loose object model (java.util.Map[String, Object] /
// Object) at runtime, so these types are not wired into the op signatures —
// use them to describe a payload before converting it to a map. Every
// component is a boxed (nullable) type, so an optional (req:false) key needs
// no distinct rendering.

object UnivecTypes {

  final case class Convert(bridge_model: String, embeddings: java.util.List[Object], source_model: String, target_model: String, texts: java.util.List[Object])

  final case class ConvertCreateData(bridge_model: String, embeddings: java.util.List[Object], source_model: String, target_model: String, texts: java.util.List[Object])

  final case class Embed(embeddings: java.util.List[Object], model: String, texts: java.util.List[Object])

  final case class EmbedCreateData(embeddings: java.util.List[Object], model: String, texts: java.util.List[Object])

  final case class EphemeralKey(dailyLimit: java.lang.Long, dailyUsed: java.lang.Long, key: String, resetsAt: String)

  final case class EphemeralKeyCreateData(dailyLimit: java.lang.Long, dailyUsed: java.lang.Long, key: String, resetsAt: String)

  final case class Model(eval: java.util.Map[String, Object], executionProvider: String, modelCard: java.util.Map[String, Object], modelType: String, name: String, sequenceLen: java.lang.Long, sourceDim: java.lang.Long, sourceModel: String, targetDim: java.lang.Long, targetModel: String)

  final case class ModelListMatch(eval: java.util.Map[String, Object], executionProvider: String, modelCard: java.util.Map[String, Object], modelType: String, name: String, sequenceLen: java.lang.Long, sourceDim: java.lang.Long, sourceModel: String, targetDim: java.lang.Long, targetModel: String)

}
